# One host folder whatever the environment

**What to build:** on macOS and Windows the analysis host's folder still comes from environment variables, so two clients of one user on one machine can choose different folders and start a host and an analysis server each. macOS takes `$TMPDIR`; an SSH session usually has none, and its client then uses `appstein-<uid>` in the shared `/tmp`, where another user can make that folder first (the case ticket 12 solved on Linux). Windows takes `%LOCALAPPDATA%`; a process started without it falls to another folder. Ticket 12 chose Linux's folder from what every process of the user shares; this ticket does the same on macOS and Windows (the owner, 2026-10-22).

**Blocked by:** 12.

Status: ready-for-agent

- [ ] macOS: the folder is `appstein` in the user's own temporary folder as the system names it (`getconf DARWIN_USER_TEMP_DIR`), not `$TMPDIR`, so a client in an SSH session or with any `TMPDIR` finds the same host, and the shared `/tmp` is never used. When the system can't name it, the user's `Library/Caches/appstein/hosts/<machine>` under the home from the user database, with ticket 12's checks.
- [ ] Windows: the folder is `appstein` in the Local AppData known folder of the user as the system names it, not `%LOCALAPPDATA%`.
- [ ] The last place before the shared temporary folder, on every system: `appstein/host` in the project's own `.dart_tool` (ignored by git in Flutter projects), used only when every folder from the project root down to it is the user's own and no other user can write to it (the owner, 2026-10-22). So a user with no folder of their own outside the project (Linux with no `/run/user/<uid>`, no usable home, and `/tmp/appstein-<uid>` taken by another user) still gets a host, and their hooks answer within 5 s instead of starting a cold server each time. The slice spec's "outside the project" becomes "outside the project, or in its `.dart_tool` as a last resort".
- [ ] Every client, the host and the measurement tool find the same folder; `APPSTEIN_ANALYSIS_HOST_FOLDER` still moves it; a host follows its folder as in ticket 12; what it costs a hook run is measured (no process start on Windows).
- [ ] Tests: the choice with the system's answers given by the test, on every system; that `TMPDIR` and `LOCALAPPDATA` change nothing; on macOS and Windows, the real folder.
- [ ] The guide, the slice spec and ticket 02 state the rule.

## Comments
