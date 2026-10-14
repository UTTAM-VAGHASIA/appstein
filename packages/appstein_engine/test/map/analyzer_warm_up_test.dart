import 'dart:async';

import 'package:test/test.dart';

import '../support/analyzer_warm_up.dart';

// `warmUpAnalyzer` (support/analyzer_warm_up.dart) is called by `setUpAll` in
// the files that analyze. This tests the one path they rarely take: a warm-up
// that outlasts its limit.
void main() {
  setUpAll(warmUpAnalyzer);

  test('a warm-up that outlasts its limit fails with a message that says so; '
      'its analysis is waited for before the folder is deleted, so the end of '
      'the test adds no second error', () async {
    await expectLater(
      warmUpAnalyzer(limit: const Duration(milliseconds: 1)),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          allOf(contains('more than 0.001 s'), contains('first analysis')),
        ),
      ),
    );
    // The analysis it started is still running here. The teardowns, which
    // end this test, wait for it and then delete the fixture's folder. Whether
    // the analysis would still be reading files when a folder is deleted
    // under it depends on the machine's speed, so this checks that the path
    // runs and ends clean, not the order.
  });
}
