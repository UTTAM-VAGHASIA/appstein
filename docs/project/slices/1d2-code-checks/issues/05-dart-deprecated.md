# 05: `dart.deprecated`

**What to build:** every use of a deprecated API is an error, anywhere in the project, in fast and full runs. A standard `// ignore:` comment can't make it go away: the comment itself is reported. This is what lets Appstein check success criterion 1 of the design, "zero deprecated-API findings in final code".

**Blocked by:** 03.

**Status:** ready-for-agent

- [ ] A `deprecated_member_use` diagnostic, and each of its variants (`deprecated_member_use_from_same_package` and the others the pinned SDK has), is a `dart.deprecated` error with the file, the line, the analyzer's message and its code.
- [ ] It is reported wherever it is in the project, in a fast run too.
- [ ] An `// ignore:` comment that names one of those codes is a `dart.deprecated` error on the comment's line, saying that it hides a deprecated API and naming the visible way out (a suppression with a reason, design §9.7). The same for `// ignore_for_file:`.
- [ ] An `// ignore:` that names only other codes is not reported. Text that looks like such a comment inside a string or a doc comment's code sample is not reported.
- [ ] Each finding has a fix hint. In this ticket it is the general one; ticket 06 makes it specific on the unverified files.
- [ ] A fixture app has a passing and a failing case for the diagnostic and for the hiding comment.
- [ ] `dart.deprecated` can be overridden with `verify.severity` and hidden by an `appstein.yaml` suppression with a reason.
- [ ] The guide page for the checks is updated; the guide check passes.
