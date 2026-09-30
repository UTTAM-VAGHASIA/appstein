import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'doc_comments.dart';

/// Thrown when a generated section can't be rendered, for example because a
/// doctor check has no doc comment.
final class GenerateException implements Exception {
  /// Creates the exception.
  const GenerateException(this.message);

  /// What is missing, and where.
  final String message;

  @override
  String toString() => message;
}

/// Renders the body of every generated section of the guide (spec §19.6),
/// by section name. Links are relative to `docs/guide/`.
Future<Map<String, String>> renderSections(String repoRoot) async => {
  'cli-help': await renderCliHelp(),
  'exit-codes': renderExitCodes(repoRoot),
  'doctor-checks': renderDoctorChecks(repoRoot),
  'ci-jobs': renderCiJobs(repoRoot),
  'package-graph': renderPackageGraph(repoRoot),
};

/// A table of the checks `appstein doctor` runs, in the order it shows
/// them. Each row gives the ID, the title, the first paragraph of the
/// check's doc comment and a link to its file.
String renderDoctorChecks(String repoRoot) {
  const folder = 'packages/appstein_engine/lib/src/doctor/checks';
  final files =
      Directory(p.join(repoRoot, folder))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final rows = [
    '| # | ID | Shown as | What it checks | Code |',
    '|---|---|---|---|---|',
  ];
  var number = 0;
  for (final check in defaultDoctorChecks()) {
    final idPattern = RegExp("\\bid(\\s*=>|:)\\s*'${RegExp.escape(check.id)}'");
    String? summary;
    String? path;
    for (final file in files) {
      final lines = file.readAsLinesSync();
      final at = lines.indexWhere(idPattern.hasMatch);
      if (at < 0) continue;
      var start = at;
      while (start > 0 && !_isTopLevelDeclaration(lines[start])) {
        start--;
      }
      final doc = docCommentAbove(lines, start);
      if (doc == null) {
        throw GenerateException(
          '${check.id} has no /// doc comment on its declaration in '
          '${p.basename(file.path)}.',
        );
      }
      summary = firstParagraph(doc);
      path = '$folder/${p.basename(file.path)}';
      break;
    }
    if (summary == null || path == null) {
      throw GenerateException('No declaration in $folder has id ${check.id}.');
    }
    number++;
    rows.add(
      '| $number | `${check.id}` | ${check.title.replaceAll('|', r'\|')} | '
      '$summary | [${p.posix.basename(path)}](../../$path) |',
    );
  }
  return rows.join('\n');
}

/// Whether [line] starts a top-level declaration: it isn't indented, and
/// isn't a closing bracket, comment or annotation.
bool _isTopLevelDeclaration(String line) =>
    line.isNotEmpty && !line.startsWith(RegExp(r'[\s})\]/@]'));

/// A table of the exit codes in `ExitCodes`, sorted by code, each with the
/// first paragraph of its doc comment.
String renderExitCodes(String repoRoot) {
  const file = 'packages/appstein_cli/lib/src/exit_codes.dart';
  final lines = File(p.join(repoRoot, file)).readAsLinesSync();
  final constant = RegExp(r'^\s*static const (\w+) = (\d+);');
  final rows = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final match = constant.firstMatch(lines[i]);
    if (match == null) continue;
    final doc = docCommentAbove(lines, i);
    if (doc == null) {
      throw GenerateException('ExitCodes.${match[1]} has no /// doc comment.');
    }
    rows.add((
      int.parse(match[2]!),
      '| `${match[2]}` | `ExitCodes.${match[1]}` | ${firstParagraph(doc)} |',
    ));
  }
  if (rows.isEmpty) throw GenerateException('No exit codes found in $file.');
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    '| Code | Name | Meaning |',
    '|---|---|---|',
    for (final row in rows) row.$2,
    '',
    'Defined in [exit_codes.dart](../../$file).',
  ].join('\n');
}

/// The CLI's own `--help` text, and each command's, exactly as `appstein`
/// prints them.
Future<String> renderCliHelp() async {
  Future<String> help(List<String> arguments) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runAppstein(arguments, out: out, err: err);
    if (code != ExitCodes.ok) {
      throw GenerateException(
        'appstein ${arguments.join(' ')} exited $code: $err',
      );
    }
    return out.toString().trimRight();
  }

  final top = await help(['--help']);
  final commands = _commandNames(top);
  if (commands.isEmpty) {
    throw const GenerateException('`appstein --help` lists no commands.');
  }
  final parts = ['```text', r'$ appstein --help', top, '```'];
  for (final command in commands) {
    parts.addAll([
      '',
      '```text',
      '\$ appstein help $command',
      await help(['help', command]),
      '```',
    ]);
  }
  return parts.join('\n');
}

List<String> _commandNames(String usage) {
  final lines = usage.split('\n');
  final start = lines.indexWhere(
    (line) => line.trim() == 'Available commands:',
  );
  if (start < 0) return const [];
  final names = <String>[];
  for (final line in lines.skip(start + 1)) {
    final match = RegExp(r'^  (\S+)\s').firstMatch(line);
    if (match == null) break;
    names.add(match[1]!);
  }
  return names;
}

/// The CI workflow's triggers, and each job with where it runs and its
/// steps, read from `.github/workflows/ci.yml`.
String renderCiJobs(String repoRoot) {
  const file = '.github/workflows/ci.yml';
  final workflow =
      loadYaml(File(p.join(repoRoot, file)).readAsStringSync()) as YamlMap;
  final triggers = workflow['on'];
  final jobs = workflow['jobs'];
  if (triggers is! YamlMap || jobs is! YamlMap) {
    throw const GenerateException(
      '$file needs an `on:` map and a `jobs:` map.',
    );
  }
  final out = [
    'Defined in [ci.yml](../../$file). Triggers: '
        '${[for (final entry in triggers.entries) _trigger('${entry.key}', entry.value)].join(', ')}.',
  ];
  for (final entry in jobs.entries) {
    final job = entry.value as YamlMap;
    final steps = job['steps'];
    if (steps is! YamlList) {
      throw GenerateException('Job ${entry.key} in $file has no steps.');
    }
    out
      ..add('')
      ..add('**`${entry.key}`** runs on ${_runsOn(job)}:')
      ..add('');
    var number = 0;
    for (final step in steps.cast<YamlMap>()) {
      number++;
      out.add('$number. ${_step(step)}');
    }
  }
  return out.join('\n');
}

String _trigger(String name, Object? value) {
  final branches = value is YamlMap ? value['branches'] : null;
  return branches is YamlList
      ? '`$name` (${branches.map((branch) => '`$branch`').join(', ')})'
      : '`$name`';
}

String _runsOn(YamlMap job) {
  final runsOn = '${job['runs-on']}';
  final strategy = job['strategy'];
  final matrix = strategy is YamlMap ? strategy['matrix'] : null;
  final os = matrix is YamlMap ? matrix['os'] : null;
  if (runsOn.contains('matrix.os') && os is YamlList) {
    return os.map((name) => '`$name`').join(', ');
  }
  return '`$runsOn`';
}

String _step(YamlMap step) {
  if (step['name'] != null) return '${step['name']}';
  if (step['uses'] != null) return '`${step['uses']}`';
  return '`${'${step['run'] ?? ''}'.trim().split('\n').first}`';
}

/// A Mermaid diagram of which workspace package depends on which, read from
/// the pubspecs. Dev dependencies are left out.
String renderPackageGraph(String repoRoot) {
  final workspace =
      loadYaml(File(p.join(repoRoot, 'pubspec.yaml')).readAsStringSync())
          as YamlMap;
  final members = workspace['workspace'];
  if (members is! YamlList) {
    throw const GenerateException('The root pubspec.yaml has no workspace.');
  }
  final dependencies = <String, List<String>>{};
  for (final member in members) {
    final pubspec =
        loadYaml(
              File(
                p.join(repoRoot, '$member', 'pubspec.yaml'),
              ).readAsStringSync(),
            )
            as YamlMap;
    final deps = pubspec['dependencies'];
    dependencies['${pubspec['name']}'] = deps is YamlMap
        ? [for (final name in deps.keys) '$name']
        : const [];
  }
  final names = dependencies.keys.toList()..sort();
  final lines = ['```mermaid', 'graph LR'];
  for (final name in names) {
    final internal =
        dependencies[name]!.where(dependencies.containsKey).toList()..sort();
    if (internal.isEmpty) {
      final usedBySome = dependencies.values.any((deps) => deps.contains(name));
      if (!usedBySome) lines.add('  $name');
    }
    for (final dependency in internal) {
      lines.add('  $name --> $dependency');
    }
  }
  lines
    ..add('```')
    ..add('')
    ..add(
      'An arrow means "depends on". Read from each package\'s '
      '`pubspec.yaml`; dev dependencies are left out.',
    );
  return lines.join('\n');
}
