# 01: Fixes carried from 1d.1

**What to build:** three faults the final review of slice 1d.1 found and left for this slice are gone. A decision's path can name a file whose name holds a glob character. `appstein.yaml` refuses a suppression path that can never match. The CLI's own tests can verify a healthy project, which every later ticket of this slice needs.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A decision whose `paths` entry escapes a glob character with a backslash (`lib/a\[1\].dart`) passes `paths.exist` when a file named `a[1].dart` exists, and reports `decision.drift` when it doesn't. A backslash used as a path separator still works on Windows.
- [ ] Loading `appstein.yaml` with a suppression whose `path` is drive-relative (`C:foo`) fails with the same kind of message as the other absolute forms, naming the entry.
- [ ] The CLI's in-process tests are given the real Dart SDK path the engine's tests use, so the knowledge of a healthy fixture project can be built in them.
- [ ] A CLI test runs `appstein verify` on a healthy project and sees exit code 0 with the "no findings" summary, in text and in JSON.
- [ ] Each fix was written test first, and its test was seen failing on behaviour before the fix.
- [ ] The guide pages that cover the changed files are updated, and the guide check passes.
