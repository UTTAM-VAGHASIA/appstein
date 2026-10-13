import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import '../../support/fixture_app.dart';

/// A file of `test/analysis/support/`, found from the package itself: other
/// test files change the working folder.
String analysisSupportFile(String name) {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  return p.join(
    p.dirname(p.dirname(library.toFilePath())),
    'test',
    'analysis',
    'support',
    name,
  );
}

/// The command that starts the guard in the engine's tests: the `dart` that
/// runs the tests, and `guard_main.dart`.
List<String> get testGuardCommand => [
  Platform.resolvedExecutable,
  analysisSupportFile('guard_main.dart'),
];

/// The real `dart` executable of the SDK that runs the tests.
String get testDart => dartExecutableIn(testDartSdk);

/// A real analysis server for the project at [app], with the SDK that runs
/// the tests. The caller stops it.
AnalysisServer realAnalysisServer(String app) => AnalysisServer(
  projectRoot: app,
  guardCommand: testGuardCommand,
  dartExecutable: () => testDart,
);

/// Writes [content] to the file [relative] (with `/`) of the project [app].
void writeProjectFile(String app, String relative, String content) =>
    File(p.joinAll([app, ...relative.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

/// Whether a process with this ID is running.
Future<bool> processAlive(int id) async {
  if (Platform.isWindows) {
    final list = await Process.run('tasklist', [
      '/FI',
      'PID eq $id',
      '/FO',
      'CSV',
      '/NH',
    ]);
    return '${list.stdout}'.contains('"$id"');
  }
  return (await Process.run('ps', ['-p', '$id'])).exitCode == 0;
}

/// How long until none of the processes [ids] is running, or null when one
/// still is after [limit].
Future<Duration?> goneWithin(Iterable<int> ids, Duration limit) async {
  final watch = Stopwatch()..start();
  while (true) {
    var any = false;
    for (final id in ids) {
      if (await processAlive(id)) any = true;
    }
    if (!any) return watch.elapsed;
    if (watch.elapsed > limit) return null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
