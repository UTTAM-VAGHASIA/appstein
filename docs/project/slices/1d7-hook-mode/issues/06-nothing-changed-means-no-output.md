# Nothing changed means no output

**What to build:** after a command that changed nothing Appstein reads (`ls`, `git status`, an edit to a README), the hook exits 0 with no output and runs no check, at the cost of one hash scan. "Nothing changed" is judged against this session's own last hook run, so another session's work on the project never makes this session miss its own edit (spec: "Nothing changed means no output").

**Blocked by:** 05.

Status: ready-for-agent

- [ ] Per session, the hook keeps a fingerprint of the input hashes it last saw, in a git-ignored record under `.appstein/` (beside `state.json`). Records not touched for a day are deleted.
- [ ] A fast hook run whose fingerprint equals the session's last one exits 0 with no output and runs no check.
- [ ] A session's first hook run, and a run with no session (missing input), always check.
- [ ] Tested: session A edits a file, session B's `appstein mcp` refreshes the knowledge (using up the change in `state.json`), then A's hook still checks and reports A's error.
- [ ] An edit to a file Appstein doesn't read gives no output; an edit to a Dart file, `pubspec.yaml` or another file the knowledge reads gives a check.
- [ ] Errors already reported stay in the unverified files; a silent run never lets a file leave them.
- [ ] Two hooks of one session writing the record at once leave it whole (the record is replaced whole, under the knowledge lock or its own).
- [ ] The guide page for the verifier describes the rule and why it is per session; the guide check passes.
