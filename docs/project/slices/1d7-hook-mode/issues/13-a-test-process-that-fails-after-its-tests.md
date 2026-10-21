# A test process that fails after its tests

**What to build:** `flutter test` can report an error on a file's loading test after that file's tests have already run and been reported. `appstein verify` reads that as a file that could not be loaded and tells the user "The test file could not be loaded", which is wrong: the file loaded and its tests ran. It was seen once, on Linux, in CI run 39565003192 (`test_run_real_sdk_test.dart`, 2026-10-21), where the log kept only which file it was, not the error's text. The likely cause, read from Flutter's source, is a shutdown error of the `flutter_tester` process ("Shell subprocess crashed …") that Flutter's test runner adds to a suite that has finished; an error from the file's own code after it loaded would take the same path. The parser and its test date from slice 1d.2.

**Blocked by:** none (can start immediately).

Status: claimed

- [ ] An `error` event on a file's loading test that comes after the output reported that test done (hidden) is its own finding, not a load failure: worded truthfully, e.g. "The test process of this file ended with an error after its tests ran: …", with the error's text. It stays an error, since Flutter fails the run for it (the owner, 2026-10-21).
- [ ] A real load failure (an error before the loading test is done) is reported as today.
- [ ] Tests with scripted `flutter test` output for both orders, and the check's wording for the new finding, in text and JSON.
- [ ] The real-SDK integration test accepts the new finding for a file whose tests all ran, and prints `flutter test`'s last events when it fails, so the next occurrence shows the actual error.
- [ ] The guide pages that cover the test run and the `test.failed` check describe the new finding.

## Comments
