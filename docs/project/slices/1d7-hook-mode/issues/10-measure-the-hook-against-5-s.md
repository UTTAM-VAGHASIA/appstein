# Measure the hook against 5 s

**What to build:** the proof of design §15's 5 s target where an agent meets it: `tool/measure_sync.dart` times the compiled `appstein verify --fast --hook claude` from its process start to its exit, with the project's analysis host ready, on Linux, macOS and Windows in CI. It also records the hook with no host running, and checks that sessions share one analysis server (spec: "Measuring").

**Blocked by:** 04, 06, 09.

Status: ready-for-agent

- [ ] **The hook row:** on the 200-file app with a ready host, edit one file to add an error, then run the compiled hook with Claude Code's input on stdin, timed from process start to exit. Each of the three runs follows its own edit (or uses its own session ID), so ticket 06's "nothing changed" rule never makes a run silent. The median of three must be under 5 s (5.000 s or more fails), and every run must exit 2 and name the error.
- [ ] **The cold row:** the same hook with no host running (it starts one and waits), recorded with no limit other than the cap; whether it reached the cap is printed.
- [ ] **The sharing check:** two `appstein mcp` processes and a hook on one project leave exactly one analysis server running, or the tool fails; the memory of two sessions is recorded beside that of one.
- [ ] The 1d.2 rows still pass: the `verify` tool (now through the host) and the terminal runs.
- [ ] The tool's own logic is tested as 1d.2's measurement tool is (scripted processes).
- [ ] The owner is asked before CI is run for the numbers. If the hook row misses 5 s anywhere, stop and ask the owner; never change the limit. The fallback considered is the host running the whole `verify` (decision record 0002).
- [ ] The numbers from a fully green CI run are written into the spec's Further Notes, and §9.1's "still to prove" is replaced by them; the guide page for CI and the measurement is updated. The guide check passes.
