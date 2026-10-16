# The guard cleans up after its own server

**What to build:** the guard that stands in front of the analysis server deletes that server's half-written cache files (`-temp-<the server's process ID>`) every time it ends the server: when its input closes because its parent ended in any way, and on a normal stop. The parent no longer does this clean-up. A killed `appstein mcp`, or a killed terminal run, leaves no such file behind (spec: "The guard cleans up after its server"; 1d.2 notes, decided at the close, 3).

**Blocked by:** None (can start immediately).

Status: ready-for-agent

- [ ] When the guard's input closes (its parent killed), it ends the server, waits until the server is shown to be gone, and deletes only that server's `-temp-<pid>` files in the cache folder the server used. Tested by killing the parent of a real guard and server on a fixture app, on Windows too.
- [ ] On a normal stop the guard does the same clean-up; the parent's own clean-up after `stop()` is removed, and nothing is deleted twice or left behind.
- [ ] The rules of 1d.2's clean-up are kept: only files directly in the cache's analysis-driver folder, only that server's process ID, never following a link, never throwing.
- [ ] A guard killed together with its server (both ended at once) leaves the files: written in the guide as a known limit, replacing the 1d.2 limit "a killed `appstein mcp` leaves its server's half-written files".
- [ ] A terminal run still ends only after the clean-up is done, so tests that count files after a run stay valid.
- [ ] The guide pages that cover the guard and the analysis server say who cleans up; the guide check passes.
