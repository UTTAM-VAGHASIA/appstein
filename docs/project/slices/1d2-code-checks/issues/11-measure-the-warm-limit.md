# Measure the warm limit

**What to build:** the 5 s limit for a fast run (design §15) is measured where an agent meets it: on the `verify` tool of a running `appstein mcp`, after one file is edited. CI holds that number to the limit on Linux, macOS and Windows. The terminal runs, which start their own analysis server, are timed and recorded with no limit.

**Blocked by:** 04, 06.

Status: ready-for-agent

- [ ] The measurement tool starts the compiled `appstein mcp` on the 200-file app, waits until warm analysis is ready, edits one file, calls the `verify` tool with the fast scope, and takes the median of three. More than 5 s fails the run, with a message giving the measured time.
- [ ] The edit in the measurement introduces a real error, and the measurement fails if the reply doesn't report it, so a fast answer that missed the change can't pass.
- [ ] The terminal `appstein verify --fast` and the terminal full run are timed and recorded with no limit; the old 5 s limit on the terminal fast run is removed.
- [ ] The analysis server's start-up time and its memory are recorded with them.
- [ ] CI runs the measurement on Linux, macOS and Windows, and the numbers of one green run on each are written into the slice's spec beside the interview's numbers.
- [ ] If the warm fast run exceeds 5 s on any of the three, work stops and the owner is asked: the design's limit is not changed to fit.
- [ ] The guide page that describes the measurements is updated; the guide check passes.
