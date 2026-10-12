# 04: Warm analysis in `appstein mcp`

**What to build:** the `verify` MCP tool answers from warm analysis. `appstein mcp` starts the project's analysis server in the background when it starts, keeps it running between calls, and stops it when it stops. An agent that edits a file and calls `verify` gets the new findings without the server being started again (decision record 0001).

**Blocked by:** 03.

**Status:** ready-for-agent

- [ ] Starting `appstein mcp` starts one analysis server for the project without delaying the server's first replies to other tools.
- [ ] A `verify` call made before the analysis server is ready waits for it and then answers.
- [ ] Two `verify` calls with an edit between them use the same analysis server, and the second reports the change: an error added on disk between the calls appears, and an error removed is gone.
- [ ] The findings of the tool equal the findings of a terminal run on the same project state.
- [ ] When `appstein mcp` stops (its input closes, or it is killed), the analysis server stops too. Checked on Windows.
- [ ] An analysis server that died is started again by the next `verify` call. When it can't be started, the tool's reply is an error with the reason and "run `appstein doctor`", and the MCP server keeps running.
- [ ] The other tools are unaffected: none of them waits for the analysis server.
- [ ] The guide pages for the MCP server and the verifier say how warm analysis works; the guide check passes.
