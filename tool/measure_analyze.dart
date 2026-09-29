import 'dart:io';

import 'package:path/path.dart' as p;

/// Measures `dart analyze` with and without the appstein_lints plugin on a
/// fresh Flutter app with about 200 generated files (spec §9.1, §15).
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_analyze.dart --flutter `path to flutter(.bat)`
/// Prints a Markdown table to paste into the slice 1a plan.
Future<void> main(List<String> arguments) async {
  final flutterIndex = arguments.indexOf('--flutter');
  final flutter = flutterIndex >= 0 && flutterIndex + 1 < arguments.length
      ? arguments[flutterIndex + 1]
      : 'flutter';
  final dart = Platform.resolvedExecutable;
  final repo = Directory.current.path;
  final work = Directory.systemTemp.createTempSync('appstein measure ');
  final app = p.join(work.path, 'measure app');
  try {
    await _run(flutter, [
      'create',
      '--project-name',
      'measure_app',
      '--platforms',
      'android,ios',
      app,
    ], work.path);
    _generateFiles(app, features: 50);
    final withPlugin =
        '''
include: package:flutter_lints/flutter.yaml

plugins:
  appstein_lints:
    path: ${p.join(repo, 'packages', 'appstein_lints').replaceAll(r'\', '/')}
    diagnostics:
      layer_imports: true

appstein_lints:
  layers:
    ui: [lib/ui/**]
    data: [lib/data/**]
    domain: [lib/domain/**]
  allow:
    ui: [data, domain]
    data: [domain]
    domain: []
''';
    const withoutPlugin = 'include: package:flutter_lints/flutter.yaml\n';
    final options = File(p.join(app, 'analysis_options.yaml'));
    final oneFile = p.join('lib', 'ui', 'feature_0', 'feature_0_screen.dart');

    options.writeAsStringSync(withoutPlugin);
    final baseline = await _median(
      () => _time(dart, ['analyze', oneFile], app),
    );

    options.writeAsStringSync(withPlugin);
    final firstRun = await _time(dart, ['analyze'], app); // compiles the plugin
    final wholeProject = await _median(() => _time(dart, ['analyze'], app));
    final single = await _median(() => _time(dart, ['analyze', oneFile], app));

    stdout.writeln('''
| Measurement (${Platform.operatingSystem}) | Time |
|---|---|
| Single file, no plugin (median of 3) | $baseline ms |
| Whole project, first run with plugin (includes plugin build) | $firstRun ms |
| Whole project with plugin (median of 3) | $wholeProject ms |
| **Single file with plugin (median of 3)** | **$single ms** |
''');
  } finally {
    work.deleteSync(recursive: true);
  }
}

void _generateFiles(String app, {required int features}) {
  for (var i = 0; i < features; i++) {
    void write(String relative, String content) {
      File(p.join(app, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    write(
      'lib/domain/models/model_$i.dart',
      'class Model$i {\n'
          '  const Model$i(this.id);\n  final int id;\n}\n',
    );
    write(
      'lib/data/repositories/repo_$i.dart',
      "import '../../domain/models/model_$i.dart';\n\n"
          'class Repo$i {\n  Model$i load() => const Model$i($i);\n}\n',
    );
    write(
      'lib/ui/feature_$i/feature_${i}_view_model.dart',
      "import 'package:flutter/foundation.dart';\n"
          "import '../../data/repositories/repo_$i.dart';\n\n"
          'class Feature${i}ViewModel extends ChangeNotifier {\n'
          '  Feature${i}ViewModel(this.repo);\n  final Repo$i repo;\n}\n',
    );
    write(
      'lib/ui/feature_$i/feature_${i}_screen.dart',
      "import 'package:flutter/material.dart';\n"
          "import 'feature_${i}_view_model.dart';\n\n"
          'class Feature${i}Screen extends StatelessWidget {\n'
          '  const Feature${i}Screen({super.key, required this.viewModel});\n'
          '  final Feature${i}ViewModel viewModel;\n'
          '  @override\n  Widget build(BuildContext context) => const Placeholder();\n}\n',
    );
  }
}

Future<int> _median(Future<int> Function() measure) async {
  final times = [await measure(), await measure(), await measure()]..sort();
  return times[1];
}

Future<int> _time(String executable, List<String> args, String cwd) async {
  final watch = Stopwatch()..start();
  await _run(executable, args, cwd, allowFailure: true);
  return watch.elapsedMilliseconds;
}

/// Runs [executable] directly, with no shell. On Windows a shell does not
/// quote an executable path that contains spaces, but a `.bat` started by its
/// full path works, and so does a bare name resolved from PATH on Linux.
Future<void> _run(
  String executable,
  List<String> args,
  String cwd, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(executable, args, workingDirectory: cwd);
  if (result.exitCode != 0 && !allowFailure) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}
