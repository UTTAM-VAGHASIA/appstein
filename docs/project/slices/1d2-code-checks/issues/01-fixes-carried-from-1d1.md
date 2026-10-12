# 01: Fixes carried from 1d.1

**What to build:** three faults the final review of slice 1d.1 found and left for this slice are gone. A decision's path can name a file whose name holds a glob character. `appstein.yaml` refuses a suppression path that can never match. The CLI's own tests can verify a healthy project, which every later ticket of this slice needs.

**Blocked by:** None (can start immediately).

**Status:** resolved

- [x] A decision whose `paths` entry escapes a glob character with a backslash (`lib/a\[1\].dart`) passes `paths.exist` when a file named `a[1].dart` exists, and reports `decision.drift` when it doesn't. A backslash used as a path separator still works on Windows.
- [x] Loading `appstein.yaml` with a suppression whose `path` is drive-relative (`C:foo`) fails with the same kind of message as the other absolute forms, naming the entry.
- [x] The CLI's in-process tests are given the real Dart SDK path the engine's tests use, so the knowledge of a healthy fixture project can be built in them.
- [x] A CLI test runs `appstein verify` on a healthy project and sees exit code 0 with the "no findings" summary, in text and in JSON.
- [x] Each fix was written test first, and its test was seen failing on behaviour before the fix.
- [x] The guide pages that cover the changed files are updated, and the guide check passes.

## Comments

**2026-10-12, rulings made while building, after an independent review:**

- **A backslash in a decision's path has two readings.** It is a Windows separator or an escape, and the text can't say which. Appstein reads the path both ways (a `\` before `[`, `]`, `{` or `}` as an escape; every `\` as a separator), and the path holds when either reading names a file. Every path that worked before the ticket still works. One function does this for `paths.exist`, the `decisions` tool and `record_decision`; the review found that the first fix had reached only `paths.exist`.
- **`record_decision` stores the escape reading** when it is a valid pattern, and the separator reading otherwise.
- **In a decision file's YAML**, a backslash inside double quotes or a `[...]` list must be doubled. The guide says so.
- **The drive-letter and absolute-path rules** for a suppression's path run on the trimmed, normalised path, so `./C:foo` and `" /docs"` are refused too.
- **The healthy-project test** runs with the default configuration, after rendering the project's docs.
- **Left as they are:** a suppression path such as `{C:foo,lib}` is accepted, and one that starts with a one-letter name and a colon (`a:b`) is refused. A link whose name is written with an escape is reported as found, as one matched by a wildcard already was; nothing is followed through it.
