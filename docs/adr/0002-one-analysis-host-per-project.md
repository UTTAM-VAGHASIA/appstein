---
status: accepted
---

# One analysis host per project, reached over loopback TCP

The analysis server that verify's code checks ask (decision record 0001) is owned by an **analysis host**: the `appstein` binary in a hidden mode of its own, one per project, started in the background by the first fast hook or `verify` tool call that needs it, and ending itself after 10 minutes with no questions. Every `appstein mcp`, every hook and every session working on the project is its client. A hook process lives for about a second, so the warm server has to live somewhere else; and one analysis server serves exactly one client over its stdio, so sharing it across sessions needs a process of Appstein's own in front of it. Decided by the owner on 2026-10-17, during the design interview for slice 1d.7.

The host listens on loopback TCP (`127.0.0.1`, a port the system picks), never on another interface. It writes the port, a random secret, its process ID and its Appstein version to an **address file** in a folder of the user's, named by a hash of the project's path; only the user can read it. A client reads the file and sends the secret first; the host closes any connection that doesn't. Every local program can reach a loopback port, so the secret, which only the user's own processes can read, is what keeps others out. Changed from a Unix domain socket by the owner on 2026-10-17, the same day (see below).

## Considered options

- **Each `appstein mcp` keeps its own server, and the hook talks to whichever is running.** Cheapest, but three sessions still hold three servers (0.6 to 1.5 GB each), which decision record 0001 ("Memory") does not accept.
- **The first `appstein mcp` owns the server and the others are its clients.** When that session closes, the others lose the server in the middle of their work, so ownership must pass to another session: a hand-over that is easy to get wrong.
- **A Unix domain socket on all three systems** (chosen first). Dart supports them on Windows since 3.11, and the socket file's permissions would have kept other users out with no secret. Rejected after the first proof: on the owner's Windows (build 26300), a compiled Dart program that connected to one and closed the connection crashed the whole machine twice, in Windows' own driver (`afunix.sys`, bugcheck 0xD1, fault `AfUnixTlConnectEndpointDisconnect`). An advisory for a use-after-free in the same driver (CVE-2026-70565) listed no fix. A tool that can take down a developer's machine is not acceptable on any build.
- **Unix domain sockets on macOS and Linux, loopback TCP on Windows.** Two ways in to build, test and keep in step, for little gain.
- **Windows named pipes.** The native way on Windows, but `dart:io` has none, so it would need the Windows API through FFI.

## Consequences

- The hook runs `verify` in its own process (the knowledge refresh, the checks, the state) and asks the host only for the code reading. Each `appstein mcp` keeps its own map analyzer (about 0.8 GB); only the analysis server is shared. Moving the map's analyzer into the host as well would save that per session, but reworks how the MCP tools keep the knowledge fresh, so it is left for later.
- The host answers one question at a time, across sessions, because a full run's pending-fix passes put edits that are not on disk into the server for 17 to 19 s. A fast run that arrives during another session's full run waits, and may reach the `fast_timeout_seconds` cap.
- A terminal `appstein verify` uses a host that is already running, but never starts one, so CI leaves no process behind.
- The host outlives the sessions that started it, for at most 10 idle minutes. A client of another Appstein version asks it to stop and starts a new one.
- Starting is decided by creating the address file exclusively, not by binding a name: the client that loses waits for the winner's address. An address file whose host refuses the connection or has ended is left by a host that died; it is deleted, and a host is started.
- Whether Windows' firewall asks the developer anything when a program listens on `127.0.0.1` only is checked on a real Windows machine before the host is built on it.
