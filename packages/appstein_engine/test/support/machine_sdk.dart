import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The Flutter SDK Appstein finds for the repo or, failing that, with no
/// project. The min-sdk CI job installs 3.44 while the repo pins 3.47.5, so
/// there only the second lookup works. With neither, the test fails in CI
/// and is skipped elsewhere, and this returns null.
SdkDetection? machineSdk(HostEnvironment environment) {
  // The repo root, from the package itself: other test files change the
  // working folder.
  final engineLibrary = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  final repoRoot = p.dirname(
    p.dirname(p.dirname(p.dirname(engineLibrary.toFilePath()))),
  );
  for (final projectRoot in [readFvmPin(repoRoot)?.pinDirectory, null]) {
    final detection = SdkDetector(environment).detect(projectRoot: projectRoot);
    if (detection.info != null && detection.location != null) {
      return detection;
    }
  }
  const reason = 'No usable Flutter SDK on this machine.';
  if (environment.variable('CI') != null) fail(reason);
  markTestSkipped(reason);
  return null;
}
