# Suppression comments in Dart code

**What to build:** a person can hide a finding next to the code it is about, with a comment that needs a reason: `// appstein:ignore <check-id> — <reason>` for one line and `// appstein:ignore-file <check-id> — <reason>` for a file. The comments follow the same honesty rules as the suppressions in `appstein.yaml` (design §9.7), and the summary counts what they hide.

**Blocked by:** 05.

Status: resolved

- [x] `// appstein:ignore <check-id> — <reason>` at the end of a line of code hides that check's findings on that line. Alone on a line, it hides them on the next line of code.
- [x] `// appstein:ignore-file <check-id> — <reason>` anywhere before the file's first declaration hides that check's findings in the file. After the first declaration it hides nothing and is reported as unused.
- [x] The separator between the ID and the reason may be `—`, `--` or ` - `. A check ID that itself contains a hyphen is still read correctly.
- [x] One comment names one check. A comment with several IDs is reported as naming an unknown check.
- [x] The comments hide a finding of any check whose file is that Dart file, and never one of the four findings nothing can hide.
- [x] A comment without a reason is a `suppression.no_reason` error on its line and hides nothing. An ID no check of the project has is a `suppression.unknown_check` error on its line. A comment that hides nothing is a `suppression.unused` warning on its line, in a full run only, and not when its check, or a part of it, did not run.
- [x] The summary's two counts (findings hidden, suppressions that hid at least one) include the comments together with the `appstein.yaml` entries, in the text output, the JSON output and the tool's reply.
- [x] `// appstein:ignore dart.deprecated — <reason>` hides both forms of that finding from ticket 05: the diagnostic, and the `// ignore:` comment that hides one.
- [x] Text that looks like such a comment inside a string is not a comment.
- [x] The guide page for suppressions is updated; the guide check passes.

Added by the owner's decision of 2026-10-14, after the review:

- [x] A one-line `// appstein:ignore` never hides the `dart.deprecated` finding on an `// ignore_for_file:` comment (naming a deprecated-use code or `type=hint`); only `// appstein:ignore-file` or an `appstein.yaml` entry can. A line comment still hides the finding on an `// ignore:` line and the line of code after it.

## Comments

**2026-10-14, built beside ticket 06, reviewed three times, fixed twice.**

- **One reading of the files.** The comments are read from the files the analysis server analyzed (`analyzedFiles`), in the same pass as ticket 05's ignore comments: each file is read once and parsed at most once, before the knowledge lock. A run in which no check takes the code reading reads no comment. Only `//` line comments count; strings, `///` and `/* */` never do.
- **Decisions the ticket left open, judged sound by the review:** an alone comment covers the lines up to and including the next line of code (blank lines, comments and an `// ignore:` between are covered; an annotation counts as code); a finding with no line is hidden only by `ignore-file`; an `ignore-file` after the first declaration (which starts at its doc comment or annotation) is `suppression.unused` in a full run; a finding hidden by both an `appstein.yaml` entry and a comment is counted once and both are active; a `FollowingCheck` runs after the suppressions, so nothing it adds is hidden.
- **What the reviews changed:** the owner's rule above (the first review showed a line comment silencing a whole file through `ignore_for_file`, while the summary said "1 hidden"); a test that expected a count no real run gives; hints for a mistyped separator (en dash, `-` glued or alone); two comments on one line, or several IDs, are one `suppression.unknown_check` (a reason that quotes a comment in backticks, or a URL with `//`, is not a second comment); the shield of the `ignore_for_file` finding matches that finding only, not a real diagnostic on the same line; test-only seams are not exported.
- **The file-wide shield is matched by the finding's message,** produced by the same function the check uses (`deprecatedIgnoreMessage`), so the two can't drift apart. A key of its own would be sturdier; noted for later.
- **The builder's root suite showed 202 passed and 37 skipped:** its worktree had no `graphify-out/`, so the graph check's tests skipped (202 + 37 = 239, the branch's 238 + 1). The run before the commit, in the main checkout with `tool/test_all.dart` (which fails a skipped graph test), is the one that counts.
- **OPEN, not explained: one CLI test failed once, and which one is not known.** The first `tool/test_all.dart` run of this ticket in the main checkout failed the CLI suite (it took 1,166 s, against about 190 s on a quiet machine, while three helpers ran tests). The runner's failure report then printed the wrong lines and kept no output, so the failing test can't be named (the runner was fixed for this in `f3147bc`: it now shows the `[E]` line and keeps every step's output in `.dart_tool/test_all/`). It did not come back in 8 later CLI runs: 2 in full checks, 1 alone, and 5 in a row beside 3 engine suite runs for load (380 to 450 s each for the loaded ones). The CLI test this ticket adds (`verify_command_test.dart`) passed in every run whose output was seen. Carried to the slice's notes.
- **The engine's first run failed in both full checks** with a 30 s timeout in `analysis/analysis_server_test.dart` (two different tests), the real analysis-server tests the flaky-test diagnosis named; the second engine run passed 1,698 each time. Those tests get explicit limits in the flaky-test fixes committed after this ticket.
