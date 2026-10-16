---
status: accepted
---

# One analysis host per project, reached over a local socket

The analysis server that verify's code checks ask (decision record 0001) is owned by an **analysis host**: the `appstein` binary in a hidden mode of its own, one per project, started in the background by the first fast hook or `verify` tool call that needs it, and ending itself after 10 minutes with no questions. Every `appstein mcp`, every hook and every session working on the project is its client, over a Unix domain socket in a folder of the user's (named by a hash of the project's path, so long project paths fit the socket path limit). A hook process lives for about a second, so the warm server has to live somewhere else; and one analysis server serves exactly one client over its stdio, so sharing it across sessions needs a process of Appstein's own in front of it. Decided by the owner on 2026-10-17, during the design interview for slice 1d.7.

## Considered options

- **Each `appstein mcp` keeps its own server, and the hook talks to whichever is running.** Cheapest, but three sessions still hold three servers (0.6 to 1.5 GB each), which decision record 0001 ("Memory") does not accept.
- **The first `appstein mcp` owns the server and the others are its clients.** When that session closes, the others lose the server in the middle of their work, so ownership must pass to another session: a hand-over that is easy to get wrong.
- **Loopback TCP instead of a Unix domain socket.** Dart supports Unix domain sockets on Windows since 3.11 (Appstein needs 3.12), and whether Windows asks about the firewall for a loopback listener could not be confirmed.

## Consequences

- The hook runs `verify` in its own process (the knowledge refresh, the checks, the state) and asks the host only for the code reading. Each `appstein mcp` keeps its own map analyzer (about 0.8 GB); only the analysis server is shared. Moving the map's analyzer into the host as well would save that per session, but reworks how the MCP tools keep the knowledge fresh, so it is left for later.
- The host answers one question at a time, across sessions, because a full run's pending-fix passes put edits that are not on disk into the server for 17 to 19 s. A fast run that arrives during another session's full run waits, and may reach the `fast_timeout_seconds` cap.
- A terminal `appstein verify` uses a host that is already running, but never starts one, so CI leaves no process behind.
- The host outlives the sessions that started it, for at most 10 idle minutes. A client of another Appstein version asks it to stop and starts a new one.
