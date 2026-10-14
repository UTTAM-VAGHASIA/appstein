import 'dart:async';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import 'fixture_app.dart';

/// How long the warm-up may take. On a quiet machine the first analysis in a
/// test file needs 4 to 6 s; with about 16 test files starting theirs at once
/// it took 31 to 35 s. This is nearly twice the worst of those, and still far
/// below the 12 minutes `setUpAll` is allowed.
const analyzerWarmUpLimit = Duration(seconds: 60);

/// Pays the first-analysis cost of this test file, before its tests run.
///
/// Every test file runs in an isolate of its own, and the first analysis in
/// an isolate takes about 4 s more than the next ones: `package:analyzer`'s own
/// code is compiled on first use, and the operating system's file caches are
/// cold. That extra is paid once per isolate, and this pays it. What it does
/// not remove is the 1.5 s or so every new analysis spends resolving the Dart
/// SDK again in its own in-memory store: that is each test's own work.
/// Without the warm-up, the first test of a file that analyzes also pays the
/// extra, and when many test files start at once it can use up that test's
/// 30 s limit, for no fault of the test.
///
/// It analyzes the fixture app (with its stand-in packages), the project the
/// tests analyze most, so the code the tests need is the code that warms up.
///
/// Call it as `setUpAll(warmUpAnalyzer)` in a file whose tests analyze in the
/// test's own isolate. `setUpAll` has its own limit (12 minutes), so a warm-up
/// is held to [limit] here instead; when it takes longer, the file fails with
/// a message that says so, not with a mystery in one test. An analysis that is
/// still running then is waited for and disposed when the file ends, before
/// the fixture's folder is deleted under it (teardowns run in reverse order).
Future<void> warmUpAnalyzer({Duration limit = analyzerWarmUpLimit}) async {
  final app = copyFixtureApp();
  final analysing = ProjectAnalysis.analyze(app, dartSdkPath: testDartSdk);
  try {
    final analysis = await analysing.timeout(limit);
    await analysis.dispose();
  } on TimeoutException {
    addTearDown(() async {
      try {
        await (await analysing.timeout(analyzerWarmUpLimit)).dispose();
      } on Object {
        // It failed, or never ended: the folder is deleted all the same.
      }
    });
    throw TimeoutException(
      'The analyzer needed more than ${limit.inMilliseconds / 1000} s for its '
      'first '
      'analysis in this test file (see test/support/analyzer_warm_up.dart).',
    );
  }
}
