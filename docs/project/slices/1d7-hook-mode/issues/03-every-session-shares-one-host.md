# Every session shares one host

**What to build:** several sessions, hooks and tools working on one project share one analysis host and so one analysis server. The host survives the session that started it, replaces itself after an Appstein upgrade, recovers from a crash, and never mixes one client's question into another's (spec: "The analysis host", housekeeping and "One question at a time").

**Blocked by:** 02.

Status: ready-for-agent

- [ ] Two `appstein mcp` processes on one project, both calling `verify`, leave exactly one host and one analysis server running. Ending the first leaves the second's answers warm.
- [ ] Clients that start a host at the same moment end with one host: creating the address file is exclusive, and the one that loses waits for the winner's address and connects to it.
- [ ] An address file whose host refuses the connection or has ended (a host that died) is deleted and a new host is started.
- [ ] A client says its Appstein version when it connects. A host of another version is asked to stop and a new one is started; the client's answer comes from the new one.
- [ ] A change of the project's SDK (for example `fvm use` to another version) restarts the host's server; the next answer comes from the new SDK.
- [ ] The host answers one question at a time, in the order they arrive, across clients. A question asked during another client's pending-fix passes waits and never sees their temporary edits (tested with a full run's passes and a fast question from another client). A question whose client has gone away is dropped.
- [ ] A project path with spaces, letter-case differences and a long name works on Windows; two different projects get two hosts.
- [ ] The developer guide says how to find a project's host and end it by hand, and what happens to its server then.
- [ ] The guide check passes.
