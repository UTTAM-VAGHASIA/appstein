# A host folder no other user can take

**What to build:** on Linux with no `XDG_RUNTIME_DIR` (servers, containers, cron), the analysis host's folder is `/tmp/appstein-<uid>`, in the shared temporary folder. Another user can make that folder first. Nothing leaks: the host can't make it the user's own, so it writes nothing there, and the client says why. But no host runs for that user until the folder is gone, so every hook and `verify` call either fails or uses a server of its own. This ticket gives such a user a folder no one else can make, so a host always runs. Found by the CI run of ticket 10 (2026-10-21); the guide was corrected then, and ticket 02's claim that another user "can't even make it first" was wrong.

**Blocked by:** 10.

Status: ready-for-agent

- [ ] Where `XDG_RUNTIME_DIR` is not set on Linux, the host's folder is one only the user can make: `$XDG_CACHE_HOME/appstein/hosts/<machine name>`, else `~/.cache/appstein/hosts/<machine name>` (the owner, 2026-10-21). The machine name keeps two machines that share a home over the network from reading each other's address files. Windows, macOS (`$TMPDIR`, the user's own) and Linux with `XDG_RUNTIME_DIR` are unchanged.
- [ ] Every client, the host, `appstein doctor`'s view of the host (if it has one) and the measurement tool find the same folder from the same environment, with no look at the disk needed to choose it.
- [ ] The folder-mode rules of the 2026-10-21 fix hold in the new place: it is made 700, its address file 600; a client checks them once there is an address, and refuses a folder others can write to.
- [ ] Tests: the folder chosen for each environment (with and without `XDG_RUNTIME_DIR`, `XDG_CACHE_HOME`, `HOME`), and, off Windows, a folder another process made in `/tmp/appstein-<uid>` no longer stops a host from running.
- [ ] The guide's address-file section, ADR 0002 (if it names the folder) and ticket 02's comment state the new place, and the false claim is gone everywhere.

## Comments
