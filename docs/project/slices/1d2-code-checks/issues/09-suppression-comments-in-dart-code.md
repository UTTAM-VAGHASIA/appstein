# Suppression comments in Dart code

**What to build:** a person can hide a finding next to the code it is about, with a comment that needs a reason: `// appstein:ignore <check-id> — <reason>` for one line and `// appstein:ignore-file <check-id> — <reason>` for a file. The comments follow the same honesty rules as the suppressions in `appstein.yaml` (design §9.7), and the summary counts what they hide.

**Blocked by:** 05.

Status: claimed

- [ ] `// appstein:ignore <check-id> — <reason>` at the end of a line of code hides that check's findings on that line. Alone on a line, it hides them on the next line of code.
- [ ] `// appstein:ignore-file <check-id> — <reason>` anywhere before the file's first declaration hides that check's findings in the file. After the first declaration it hides nothing and is reported as unused.
- [ ] The separator between the ID and the reason may be `—`, `--` or ` - `. A check ID that itself contains a hyphen is still read correctly.
- [ ] One comment names one check. A comment with several IDs is reported as naming an unknown check.
- [ ] The comments hide a finding of any check whose file is that Dart file, and never one of the four findings nothing can hide.
- [ ] A comment without a reason is a `suppression.no_reason` error on its line and hides nothing. An ID no check of the project has is a `suppression.unknown_check` error on its line. A comment that hides nothing is a `suppression.unused` warning on its line, in a full run only, and not when its check, or a part of it, did not run.
- [ ] The summary's two counts (findings hidden, suppressions that hid at least one) include the comments together with the `appstein.yaml` entries, in the text output, the JSON output and the tool's reply.
- [ ] `// appstein:ignore dart.deprecated — <reason>` hides both forms of that finding from ticket 05: the diagnostic, and the `// ignore:` comment that hides one.
- [ ] Text that looks like such a comment inside a string is not a comment.
- [ ] The guide page for suppressions is updated; the guide check passes.

Added by the owner's decision of 2026-10-14, after the review:

- [ ] A one-line `// appstein:ignore` never hides the `dart.deprecated` finding on an `// ignore_for_file:` comment (naming a deprecated-use code or `type=hint`); only `// appstein:ignore-file` or an `appstein.yaml` entry can. A line comment still hides the finding on an `// ignore:` line and the line of code after it.
