# A terminal `verify` uses a running host

**What to build:** a terminal `appstein verify` (a person, or CI) asks the project's analysis host when one is running, so it gets warm answers. When none is running it starts its own analysis server and stops it, as in 1d.2, and never starts a host, so a CI run leaves no process behind (spec: "Who starts it").

**Blocked by:** 02.

Status: ready-for-agent

- [ ] With a host running for the project, a terminal fast run and full run ask it and start no server of their own; their findings equal the tool's.
- [ ] With no host running, a terminal run starts its own server, stops it at the end, and leaves no host, guard or server running afterwards.
- [ ] A host that stops answering during a terminal run is Appstein failing (exit 3 with the reason), as for its own server.
- [ ] A host of another Appstein version is not used by a terminal run: the run uses its own server and leaves that host alone.
- [ ] The guide page for the verifier says which route a terminal run takes; the guide check passes.
