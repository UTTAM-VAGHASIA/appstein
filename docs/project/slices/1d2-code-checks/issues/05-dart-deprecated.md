# `dart.deprecated`

**What to build:** every use of a deprecated API is an error, anywhere in the project, in fast and full runs. A standard `// ignore:` comment can't make it go away: the comment itself is reported. This is what lets Appstein check success criterion 1 of the design, "zero deprecated-API findings in final code".

**Blocked by:** 03.

Status: resolved

- [x] A `deprecated_member_use` diagnostic, and each of its variants (`deprecated_member_use_from_same_package` and the others the pinned SDK has), is a `dart.deprecated` error with the file, the line, the analyzer's message and its code.
- [x] It is reported wherever it is in the project, in a fast run too.
- [x] An `// ignore:` comment that names one of those codes is a `dart.deprecated` error on the comment's line, saying that it hides a deprecated API and naming the visible way out (a suppression with a reason, design §9.7). The same for `// ignore_for_file:`.
- [x] An `// ignore:` that names only other codes is not reported. Text that looks like such a comment inside a string or a doc comment's code sample is not reported.
- [x] Each finding has a fix hint. In this ticket it is the general one; ticket 06 makes it specific on the unverified files.
- [x] A fixture app has a passing and a failing case for the diagnostic and for the hiding comment.
- [x] `dart.deprecated` can be overridden with `verify.severity` and hidden by an `appstein.yaml` suppression with a reason.
- [x] The guide page for the checks is updated; the guide check passes.

Added by the owner's decisions of 2026-10-14, after the first review:

- [x] A comment that says `type=hint` (`// ignore:` or `// ignore_for_file:`) is a `dart.deprecated` error on its line; one that says `type=lint` is not reported.
- [x] An `analyzer: errors:` entry that sets a deprecated-use diagnostic to `ignore` (or `false`) is a `dart.deprecated` error on its line, in every `analysis_options.yaml` the analysis covers and in the nearest one above the project when the project has none.
- [x] A deprecated use the project raised to error level is reported once, as `dart.deprecated`.

## Comments

**2026-10-14, built in a copy of the repo beside ticket 04, reviewed twice, fixed twice.**

- **How the hiding comments are found.** The analysis server's reading now lists every file it analyzed (`CodeReading.analyzedFiles`; the server sends `analysis.errors` for each, with an empty list for a clean one). Exactly those files are read, before the knowledge lock, and a file is parsed only when its text can hold such a comment. Which comments count is decided by the pinned `analyzer` package's own code, so it is the engine's rule, not the project SDK's.
- **What the first version cost, and why it changed.** It found the files with the analyzer's context locator: 362 to 435 ms per run on a 200-file app, about 2 s on 1,000 files, and 1.7 s with a `build/` folder of 5,000 files. With the server's list: 28 to 49 ms, 158 to 218 ms, and 25 to 35 ms (the reviewer's numbers, run from source).
- **The names.** Seven names count in a comment: four the pinned analyzer package has (a test fails if an upgrade changes them) and three of the SDK's lint, established by running `dart analyze`. In `analysis_options.yaml` the analyzer accepts only `deprecated_member_use` and `deprecated_member_use_from_same_package`, in any letter case; the others are rejected as unrecognized and are not reported.
- **A comment is reported for naming the code,** whether or not the analyzer honours it at that spot. The message says that, and doesn't claim a use is hidden.
- **An options file above the project** is read when the project has none of its own, as the analyzer does (the nearest one wins; a project's own file, even an empty one, switches the one above off). Its finding is on `../analysis_options.yaml`. A suppression can't hide it, since a suppression's path must be inside the project; the fix hint says to remove the entry or give the project its own options file.
- **An `include:` of a local file is followed** (the owner's decision of 2026-10-14), and a switch-off in the included file is a finding on that file, naming the options files that include it. Each rule was compared with `dart analyze` of the pinned SDK.
- **Known limits, written in the guide:** an `include:` of a `package:` URI is not followed, though the analyzer follows it, so a shared options package can switch the diagnostic off unseen; a folder left out with `analyzer: exclude:` is not reported; no test would notice a fourth name added to the SDK's lint.
- **Wider than this ticket.** On Windows, a file another program holds locked is listed by the server with no diagnostics at all: every code check reads it as clean, `dart.error` included. Shown with a real lock. Nothing was changed for it in this ticket. The owner decided on 2026-10-14 that it is fixed in ticket 06, as a new `dart.unreadable` error.
- **For later tickets.** `dart.warning` and `dart.lint` (ticket 06) must leave out diagnostics for which `isDeprecatedUseCode` is true. The hiding comment's fix hint names only the `appstein.yaml` suppression until ticket 09 adds the Dart comment form. Other `deprecated_*` codes (`deprecated_export_use` and the like) are not covered: the spec says `deprecated_member_use*`.
