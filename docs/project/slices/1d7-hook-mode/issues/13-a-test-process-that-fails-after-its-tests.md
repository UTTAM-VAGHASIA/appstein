# A test process that fails after its tests

**What to build:** `flutter test` can report an error on a file's loading test after that file's tests have already run and been reported. `appstein verify` reads that as a file that could not be loaded and tells the user "The test file could not be loaded", which is wrong: the file loaded and its tests ran. It was seen once, on Linux, in CI run 39565003192 (`test_run_real_sdk_test.dart`, 2026-10-21), where the log kept only which file it was, not the error's text. The likely cause, read from Flutter's source, is a shutdown error of the `flutter_tester` process ("Shell subprocess crashed …") that Flutter's test runner adds to a suite that has finished; an error from the file's own code after it loaded would take the same path. The parser and its test date from slice 1d.2.

**Blocked by:** none (can start immediately).

Status: resolved

- [x] An `error` event on a file's loading test that comes after the output reported that test done (hidden) is its own finding, not a load failure: worded truthfully, "This test file reported an error after it loaded: …", with the error's text. It stays an error, since Flutter fails the run for it (the owner, 2026-10-21).
- [x] A real load failure (an error before the loading test is done) is reported as today.
- [x] Tests with scripted `flutter test` output for both orders, and the check's wording for the new finding, in text and JSON.
- [x] The real-SDK integration test accepts the new finding for a file whose tests all ran, and prints `flutter test`'s last events when it fails, so the next occurrence shows the actual error.
- [x] The guide pages that cover the test run and the `test.failed` check describe the new finding.

## Comments

**2026-10-22, built and reviewed.** Built test first by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), two fix rounds (the same helper), each checked (Opus high, then Claude).

- **How it works.** `TestFailure.afterLoading` marks a failure of a file's loading test whose error came after the output told that loading test as done (`hidden`). The parser already kept where each hidden step was told done; the first error after that sets the mark. `test.failed` words it "This test file reported an error after it loaded: <the error's text>", with no line, the same fix hint and the same ID; JSON tells the two apart by the message, as the design's JSON contract needs no field for it. The errors of a stopped run's tail stay the stop's, as before.
- **Decided by the owner (2026-10-22):** design §9's `test.failed` sentence names the new case; the visual summary lists no test findings, so it needed no change.
- **Decided by Claude:** the owner's example wording ("the test process of this file ended with an error after its tests ran") was replaced by a neutral one, because the same path also carries an uncaught async error from the test file's own code after it loaded, which can happen on Windows too, and Flutter's crash path during a test: the example would sometimes be false, and the owner asked for the wording to be true.
- **Review rounds fixed:** the builder had deleted a 1d.2 test that pinned the owner's 2026-10-16 rule (a late error at the tail of a run that was not stopped is read as before); it is restored with the new expectation. The second real-SDK test ("the passing test alone") got the same treatment as the fixture-app test. Stale `///` docs on `TestFailure`, duplicated test helpers (now `flutterTestOutputWithError` in `test/support/flutter_test_output.dart`), and docs that stated the shutdown error as observed when nothing recorded its text.
- **Proof the tests bite:** the builder showed the new tests red first (3 of 76). Claude reran them in a copy of the branch (76 of 76 green; with the mark always false, 73 passed and 3 failed), and again after the first fix round (77 of 77 green; with the mark always false, 4 failed, the restored test among them), and restored the file byte for byte.
- **Local runs (Windows):** `test/verify` 530 passed; the real-SDK integration file 3 of 3 with Flutter 3.47.5.
- **Not verified:** the real error's text and order on Linux and macOS. Both real-SDK tests now print the failures and Flutter's last events whenever they accept such a finding, so the next CI occurrence records it.
