import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../decisions/decision_store.dart';
import '../../verify/decision_check.dart';
import '../../verify/verify_check.dart';

/// The state-management packages that are not `provider`. This is the
/// pack's knowledge of its stack (spec §4, principle 3): official_mvvm holds
/// state in view models that `provider` hands to the widgets.
const _otherStateManagement = [
  'riverpod',
  'flutter_riverpod',
  'hooks_riverpod',
  'bloc',
  'flutter_bloc',
  'hydrated_bloc',
  'get',
  'mobx',
  'flutter_mobx',
  'redux',
  'flutter_redux',
  'signals',
  'signals_flutter',
  'stacked',
];

/// Whether `dependencies` in the `pubspec.yaml` of the project at
/// [projectRoot] lists `provider`. False when the file can't be read.
bool _listsProvider(String projectRoot) {
  try {
    final yaml = loadYaml(
      File(p.join(projectRoot, 'pubspec.yaml')).readAsStringSync(),
    );
    final dependencies = yaml is Map ? yaml['dependencies'] : null;
    return dependencies is Map && dependencies.containsKey('provider');
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

/// How many files a sentence names before it counts the rest.
const _named = 3;

/// `stack.provider`, official_mvvm's decision check (spec §6.7): the app
/// depends on `provider` directly, and no file under `lib/` imports another
/// state-management package.
///
/// It reads `map/deps.json`, so it isn't run while the map can't be read.
final class StackProviderCheck implements DecisionCheck {
  /// Creates the check.
  const StackProviderCheck();

  @override
  String get id => 'stack.provider';

  @override
  bool get needsMap => true;

  @override
  List<String> problems(DecisionEntry decision, VerifyContext context) {
    final packages = context.knowledge.deps.value?.packages;
    if (packages == null) return const [];
    final problems = <String>[];
    final direct = switch (packages['provider']?.dependency) {
      'direct main' => true,
      // pub's word for a package in `dependency_overrides`, whether or not
      // the app also lists it: `pubspec.yaml` says which.
      'direct overridden' => _listsProvider(context.projectRoot),
      _ => false,
    };
    if (!direct) {
      problems.add('The project does not depend on `provider`.');
    }
    for (final name in _otherStateManagement) {
      final files = [
        for (final file in packages[name]?.usages ?? const <String>[])
          if (file.startsWith('lib/')) file,
      ];
      if (files.isEmpty) continue;
      final more = files.length - _named;
      problems.add(
        '${files.length} ${files.length == 1 ? 'file' : 'files'} under lib/ '
        '${files.length == 1 ? 'imports' : 'import'} `$name`: '
        '${files.take(_named).join(', ')}'
        '${more > 0 ? ', and $more more' : ''}.',
      );
    }
    return problems;
  }
}
