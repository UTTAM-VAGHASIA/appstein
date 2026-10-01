import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;

/// Measures a full `appstein sync` of a generated app with 200 Dart files,
/// against spec §15's target: under 30 s for a 200-file app.
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_sync.dart
///
/// It finds Flutter as `appstein sync` does (FLUTTER_ROOT, FVM, PATH). The
/// first sync also fetches the packages (go_router needs the network), so
/// only the second, a full rebuild of `.appstein/` with fresh packages, is
/// held to the target. Prints a Markdown table and exits 1 when that sync
/// takes 30 s or more.
Future<void> main() async {
  final work = Directory.systemTemp.createTempSync('appstein measure sync ');
  final app = p.join(work.path, 'measure app');
  try {
    _generateApp(app, features: 99);
    final sync = KnowledgeSync(
      environment: HostEnvironment.current(),
      appsteinVersion: 'measure',
      packs: const [OfficialMvvmPack()],
    );
    final first = Stopwatch()..start();
    final report = await sync.run(app);
    first.stop();
    if (report.map?.skipped case final reason?) {
      stderr.writeln(
        'The map was skipped: $reason\n${report.map!.packagesReason}',
      );
      exitCode = 1;
      return;
    }
    Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
    final full = Stopwatch()..start();
    await sync.run(app);
    full.stop();
    final files = Directory(p.join(app, 'lib'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .length;
    stdout.writeln('''
| Measurement (${Platform.operatingSystem}, $files Dart files) | Time |
|---|---|
| First sync, including `flutter pub get` | ${first.elapsedMilliseconds} ms |
| **Full sync with fresh packages (target under 30 s)** | **${full.elapsedMilliseconds} ms** |
''');
    if (full.elapsed >= const Duration(seconds: 30)) {
      stderr.writeln(
        'A full sync took ${full.elapsed.inSeconds} s; spec §15 allows '
        'under 30 s.',
      );
      exitCode = 1;
    }
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

/// Writes an official_mvvm app: [features] features with a view model and a
/// screen each, a router with one route per feature, and `main.dart`.
void _generateApp(String app, {required int features}) {
  void write(String relative, String content) => File(p.join(app, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  write(
    'pubspec.yaml',
    'name: measure_app\npublish_to: none\n\nenvironment:\n  sdk: ^3.12.0\n\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n  go_router: ^18.0.0\n',
  );
  final imports = StringBuffer();
  final routes = StringBuffer();
  for (var i = 0; i < features; i++) {
    write(
      'lib/ui/feature_$i/view_models/feature_${i}_view_model.dart',
      "import 'package:flutter/foundation.dart';\n\n"
          "/// Feature $i's state.\n"
          'class Feature${i}ViewModel extends ChangeNotifier {\n'
          '  /// How many times it was tapped.\n'
          '  int taps = 0;\n'
          '}\n',
    );
    write(
      'lib/ui/feature_$i/widgets/feature_${i}_screen.dart',
      "import 'package:flutter/widgets.dart';\n\n"
          "import '../view_models/feature_${i}_view_model.dart';\n\n"
          "/// Feature $i's screen.\n"
          'class Feature${i}Screen extends StatelessWidget {\n'
          '  /// Creates the screen.\n'
          '  const Feature${i}Screen({super.key, required this.viewModel});\n\n'
          '  /// Its state.\n'
          '  final Feature${i}ViewModel viewModel;\n\n'
          '  @override\n'
          "  Widget build(BuildContext context) => Text('\${viewModel.taps}');\n"
          '}\n',
    );
    imports
      ..writeln(
        "import '../ui/feature_$i/view_models/feature_${i}_view_model.dart';",
      )
      ..writeln("import '../ui/feature_$i/widgets/feature_${i}_screen.dart';");
    routes.writeln(
      "    GoRoute(path: '/feature-$i', builder: (context, state) => "
      'Feature${i}Screen(viewModel: Feature${i}ViewModel())),',
    );
  }
  write(
    'lib/routing/router.dart',
    "import 'package:go_router/go_router.dart';\n\n$imports\n"
        '/// The router.\n'
        'GoRouter router() => GoRouter(\n  routes: [\n$routes  ],\n);\n',
  );
  write(
    'lib/main.dart',
    "import 'routing/router.dart';\n\n/// Starts the app.\n"
        'void main() => router();\n',
  );
}
