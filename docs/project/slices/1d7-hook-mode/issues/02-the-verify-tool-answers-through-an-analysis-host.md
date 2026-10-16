# The `verify` tool answers through an analysis host

**What to build:** the tracer bullet for the **analysis host** (decision record 0002). The `appstein` binary gains a hidden host mode that owns the project's guard and analysis server and answers code questions over loopback TCP, behind a secret only the user's own processes can read. When a `verify` tool call of `appstein mcp` needs the code analysis and no host answers, it starts one as a detached process, waits for it, and asks it. The host ends itself after 10 minutes with no questions. An agent sees the same findings as before; the server now lives in the host instead of in `appstein mcp`.

**Blocked by:** 01.

Status: ready-for-agent

- [ ] **First, the platform is proven before anything is built on it:** in the compiled binary, a loopback TCP server on `127.0.0.1` with a port the system picks and a client that sends the secret first, and a detached process started without a console window appearing that reaches the server after its starter has ended, each work on Windows, macOS and Linux in CI. On a real Windows machine, listening on `127.0.0.1` raises no firewall question. Nothing here opens a Unix domain socket: one crashed Windows itself on the owner's machine (decision record 0002). If anything fails, stop and report to the owner before going on.
- [ ] The address file (port, secret, process ID, Appstein version) is in a folder of the user's (`%LOCALAPPDATA%\appstein\` on Windows; `$XDG_RUNTIME_DIR`, else the temporary folder, on Linux and macOS), readable by the user only, named by a hash of the project root's full path, and written whole or not at all. A connection that doesn't send the secret first is closed.
- [ ] The messages are Appstein's own small protocol, defined in `appstein_protocol`, carrying the questions and answers of the code analysis interface 1d.2 built. The host's client is one more implementation of that interface; the checks don't change.
- [ ] The host keeps 1d.2's server rules: the project SDK's server behind the guard, the restarts after a change to the analysis options, the package config or `pubspec.yaml`, the 180 s start limit, the plugin and readiness rules, the barrier that keeps a reading from being older than the files, and `--apply`'s writes (atomic, files outside the project or changed since the reading left alone).
- [ ] Starting `appstein mcp` starts no host. The first `verify` call starts one and answers; later calls use it without a new start; an edit between two calls shows in the second.
- [ ] The host ends itself after 10 minutes with no questions (one named constant a test can shorten), never during a question. The next `verify` call starts a new one.
- [ ] A killed host takes its guard and server with it, and the guard cleans up (ticket 01). `appstein mcp` ending no longer ends the server: the host does, when idle.
- [ ] A host that can't start, dies or doesn't answer is Appstein failing, as in 1d.2: an error reply with the reason and "run `appstein doctor`"; the MCP server keeps running.
- [ ] The tool's findings equal a terminal run's on the same project state.
- [ ] Tests give each host its own address-file folder and cache folder, and no host, guard or server is left running after a test, on Windows too.
- [ ] The guide pages for the MCP server, the verifier and the analysis code describe the host; the guide check passes.
