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
  final flutter = _resolveFlutter(
    flutterIndex >= 0 && flutterIndex + 1 < arguments.length
        ? arguments[flutterIndex + 1]
        : 'flutter',
  );
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

    // The canary is a deliberate layer violation (domain may import nothing).
    // It exists in every run so the file set is identical, and it proves the
    // plugin ran: whole-project runs with the plugin must report layer_imports.
    File(
      p.join(app, 'lib', 'domain', 'canary.dart'),
    ).writeAsStringSync("import '../ui/feature_0/feature_0_screen.dart';\n");

    options.writeAsStringSync(withoutPlugin);
    final baseline = await _median(
      () => _time(dart, ['analyze', oneFile], app),
    );

    options.writeAsStringSync(withPlugin);
    final firstRun = await _time(
      dart,
      ['analyze'],
      app,
      expectPlugin: true,
    ); // compiles the plugin
    final wholeProject = await _median(
      () => _time(dart, ['analyze'], app, expectPlugin: true),
    );
    final single = await _median(() => _time(dart, ['analyze', oneFile], app));
    stdout.writeln('Canary check passed: layer_imports was reported.');

    stdout.writeln('''
| Measurement (${Platform.operatingSystem}) | Time |
|---|---|
| Single file, no plugin (median of 3) | $baseline ms |
| Whole project, first run with plugin (includes plugin build) | $firstRun ms |
| Whole project with plugin (median of 3) | $wholeProject ms |
| **Single file with plugin (median of 3)** | **$single ms** |
''');
  } finally {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln(
        'warning: could not delete ${work.path}; remove it by hand',
      );
    }
  }
}

/// Turns the `--flutter` value into something [Process.run] can start without
/// a shell. Accepted forms:
///
/// * a full path to `flutter` or `flutter.bat`;
/// * the bare name `flutter`, resolved from PATH;
/// * on Windows only, an MSYS path such as `/c/tools/flutter/bin/flutter`
///   (from bash `command -v`), converted to `C:\tools\flutter\bin\flutter`.
///
/// On Windows an extensionless value uses the sibling `.bat`. On other systems
/// the value is used unchanged.
String _resolveFlutter(String value) {
  if (!Platform.isWindows) return value;
  var path = value;
  final msys = RegExp(r'^/([a-zA-Z])/(.*)$').firstMatch(path);
  if (msys != null) {
    path =
        '${msys.group(1)!.toUpperCase()}:\\${msys.group(2)!.replaceAll('/', r'\')}';
  }
  if (path == 'flutter') {
    final dirs = (Platform.environment['PATH'] ?? '').split(';');
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, 'flutter.bat');
      if (File(candidate).existsSync()) return candidate;
    }
    return path;
  }
  if (p.extension(path).isEmpty && File('$path.bat').existsSync()) {
    return '$path.bat';
  }
  return path;
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

/// Times one `dart analyze` run. Exit codes 0 (clean), 1 (infos or warnings)
/// and 2 (errors) are normal analyzer results; anything else is a crash or
/// bad usage. With [expectPlugin] the output must contain `layer_imports`.
Future<int> _time(
  String executable,
  List<String> args,
  String cwd, {
  bool expectPlugin = false,
}) async {
  final watch = Stopwatch()..start();
  final result = await _run(executable, args, cwd, okExitCodes: {0, 1, 2});
  final elapsed = watch.elapsedMilliseconds;
  if (expectPlugin &&
      !'${result.stdout}${result.stderr}'.contains('layer_imports')) {
    throw StateError(
      'plugin did not run: no layer_imports diagnostic in the output:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  return elapsed;
}

/// Runs [executable] directly, with no shell. On Windows a shell does not
/// quote an executable path that contains spaces, but a `.bat` started by its
/// full path works, and so does a bare name resolved from PATH on Linux.
/// Throws unless the exit code is in [okExitCodes].
Future<ProcessResult> _run(
  String executable,
  List<String> args,
  String cwd, {
  Set<int> okExitCodes = const {0},
}) async {
  final result = await Process.run(executable, args, workingDirectory: cwd);
  if (!okExitCodes.contains(result.exitCode)) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return result;
}
