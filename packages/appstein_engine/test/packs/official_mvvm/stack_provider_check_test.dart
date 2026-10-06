import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../docs/support/docs_support.dart';
import '../../support/temp.dart';

const _check = StackProviderCheck();

PackageDependency _package({
  String dependency = 'direct main',
  List<String> usages = const [],
}) => PackageDependency(
  constraint: '^1.0.0',
  version: '1.0.0',
  dependency: dependency,
  source: 'hosted',
  usages: usages,
);

void main() {
  List<String> problems(
    Map<String, PackageDependency> packages, {
    String? pubspec,
  }) {
    final root = tempDir().path;
    if (pubspec != null) {
      File(p.join(root, 'pubspec.yaml')).writeAsStringSync(pubspec);
    }
    File(p.join(root, '.appstein', 'map', 'deps.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(DepsMap(packages: packages).toJson()));
    return _check.problems(
      decisionEntry(1, 'State is held with provider'),
      VerifyContext(
        projectRoot: root,
        config: const AppsteinConfig(),
        packs: const [OfficialMvvmPack()],
        knowledge: KnowledgeSnapshot(root),
        decisions: const DecisionSet(),
      ),
    );
  }

  test('it is `stack.provider` and reads the map', () {
    expect(_check.id, 'stack.provider');
    expect(_check.needsMap, isTrue);
  });

  test('provider as a direct dependency, and nothing else, holds', () {
    expect(
      problems({
        'provider': _package(usages: ['lib/main.dart']),
        'http': _package(usages: ['lib/data/services/api.dart']),
      }),
      isEmpty,
    );
  });

  test('provider must be a direct dependency of the app', () {
    const missing = ['The project does not depend on `provider`.'];
    expect(problems({'http': _package()}), missing);
    expect(problems({'provider': _package(dependency: 'transitive')}), missing);
    expect(problems({'provider': _package(dependency: 'direct dev')}), missing);
  });

  test('an overridden provider counts when pubspec.yaml lists it as a '
      'dependency', () {
    // pub writes `direct overridden` for a package in
    // `dependency_overrides`, whether or not the app also depends on it.
    final packages = {'provider': _package(dependency: 'direct overridden')};
    const missing = ['The project does not depend on `provider`.'];
    expect(
      problems(
        packages,
        pubspec:
            'name: app\n'
            'dependencies:\n  provider: ^6.0.0\n'
            'dependency_overrides:\n  provider: 6.1.0\n',
      ),
      isEmpty,
    );
    expect(
      problems(
        packages,
        pubspec:
            'name: app\n'
            'dev_dependencies:\n  provider: ^6.0.0\n'
            'dependency_overrides:\n  provider: 6.1.0\n',
      ),
      missing,
    );
    expect(problems(packages), missing);
    expect(problems(packages, pubspec: 'dependencies: [\n'), missing);
  });

  test('another state-management package imported under lib/ is named with '
      'its files', () {
    expect(
      problems({
        'provider': _package(),
        'flutter_riverpod': _package(
          usages: ['lib/main.dart', 'lib/ui/home/widgets/home_screen.dart'],
        ),
        'get': _package(usages: ['lib/routing/router.dart']),
      }),
      [
        '2 files under lib/ import `flutter_riverpod`: lib/main.dart, '
            'lib/ui/home/widgets/home_screen.dart.',
        '1 file under lib/ imports `get`: lib/routing/router.dart.',
      ],
    );
  });

  test('more than three files are counted, not all named', () {
    expect(
      problems({
        'provider': _package(),
        'flutter_bloc': _package(
          usages: [
            for (final name in ['a', 'b', 'c', 'd', 'e']) 'lib/$name.dart',
            'test/a_test.dart',
          ],
        ),
      }),
      [
        '5 files under lib/ import `flutter_bloc`: lib/a.dart, lib/b.dart, '
            'lib/c.dart, and 2 more.',
      ],
    );
  });

  test('a package nothing under lib/ imports is no problem', () {
    expect(
      problems({
        'provider': _package(),
        'flutter_bloc': _package(dependency: 'transitive'),
        'mobx': _package(
          dependency: 'direct dev',
          usages: ['test/store_test.dart', 'tool/gen.dart'],
        ),
      }),
      isEmpty,
    );
  });

  test('both problems are reported together', () {
    expect(
      problems({
        'riverpod': _package(usages: ['lib/main.dart']),
      }),
      [
        'The project does not depend on `provider`.',
        '1 file under lib/ imports `riverpod`: lib/main.dart.',
      ],
    );
  });
}
