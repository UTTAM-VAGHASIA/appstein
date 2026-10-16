import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The Dart SDK running the tests. The analyzer reads `dart:` libraries from
/// its `lib/`. The fake Flutter SDK has none, so a run that builds the
/// project's knowledge is given this one.
String get testDartSdk => p.dirname(p.dirname(Platform.resolvedExecutable));

/// A cache folder of its own for the analysis servers a test starts, so the
/// tests leave nothing in the cache the machine shares: a test's machine
/// names it as `ANALYZER_STATE_LOCATION_OVERRIDE` (`analysisCacheVariable`),
/// which the commands pass on to their servers.
///
/// The folder is deleted after the test. A server that is still ending
/// (one in a process the test killed) holds files in it on Windows, so the
/// delete is tried again for up to 10 s.
String testAnalysisCache() {
  final cache = Directory.systemTemp.createTempSync('appstein cache tëst ');
  addTearDown(() async {
    // A stop's clean-up may still be at work in the folder.
    await analysisCleanUpsDone();
    for (var attempt = 0; ; attempt++) {
      try {
        if (cache.existsSync()) cache.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 200) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  return cache.path;
}
