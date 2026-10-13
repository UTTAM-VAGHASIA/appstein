# Warm analysis in `appstein mcp`

**What to build:** the `verify` MCP tool answers from warm analysis. `appstein mcp` starts the project's analysis server when a `verify` call first needs it, keeps it running between calls, stops it when it has been idle for 10 minutes, and stops it when it stops itself. An agent that edits a file and calls `verify` gets the new findings without the server being started again, and a session that never verifies holds no analysis server (decision record 0001, "Memory").

**Blocked by:** 03.

Status: ready-for-agent

- [ ] Starting `appstein mcp` starts no analysis server. The first `verify` call starts one for the project, waits for it and then answers.
- [ ] An analysis server that no `verify` call has used for 10 minutes is stopped, with its guard. The next `verify` call starts it again and answers correctly. The time is one named constant, and a test can shorten it.
- [ ] A `verify` call that arrives while the server is starting, or while another call is being answered, waits and then answers; two calls never start two servers.
- [ ] Two `verify` calls with an edit between them use the same analysis server, and the second reports the change: an error added on disk between the calls appears, and an error removed is gone.
- [ ] A reading is never older than the files on disk. The review of ticket 03 saw a kept server answer from before an edit when asked at once (the error appeared 50 ms later; a deleted file's findings stayed for 2 s). The barrier must not be a wait: the reading is taken only after the server has been made to take in every change the knowledge refresh saw, and has said its analysis is done again. Tested with an edit, a new file and a deleted file, each followed at once by a call, many times in a row.
- [ ] A reading is never taken from a server that has died. Each reading follows a request the server answered in that call, so a server that died since the last call is found out by the reading, not by the one after it (see the comment on ticket 03 about a test that failed once).
- [ ] A plugin failure is reported only while it holds. On a kept server, a `dart.plugin_failed` finding whose cause was removed from `analysis_options.yaml` is gone in the next call, without restarting `appstein mcp`.
- [ ] The idle stop never fires while a call is being answered or while the server is starting.
- [ ] The findings of the tool equal the findings of a terminal run on the same project state.
- [ ] When `appstein mcp` stops (its input closes, or it is killed), the analysis server stops too. Checked on Windows.
- [ ] An analysis server that died is started again by the next `verify` call. When it can't be started, the tool's reply is an error with the reason and "run `appstein doctor`", and the MCP server keeps running.
- [ ] The other tools are unaffected: none of them waits for the analysis server.
- [ ] The guide pages for the MCP server and the verifier say how warm analysis works; the guide check passes.
