# A CI job lost with its runner runs again

**What to build:** a Windows job in CI sometimes stops in the middle of its test step: it runs until its 60-minute limit and GitHub keeps no log, so nothing shows where it stopped, and a rerun of the same commit passes. It happened in run 39551693885 (2026-10-21, "the hosted runner lost communication with the server") and run 39763006737 (2026-10-22, "the job has exceeded the maximum execution time"), both in the Windows `test` job's unit tests, which take about 30 minutes otherwise. Others report the same on GitHub's Windows runners, open and unexplained upstream (actions/runner#4632, actions/runner-images#14938); no Dart process was left on the development machine after the full local check. Today the owner must notice the dead job and rerun it by hand, and the slice's proof waits an hour each time. This ticket makes CI rerun such a job once by itself and leave a trace of where it stopped, so a hang of Appstein's own tests can still be told from a lost runner (the owner, 2026-10-22).

**Blocked by:** None (can start immediately).

Status: claimed

- [ ] A job that ended with no log because its runner was lost or froze (cancelled at the job's time limit, or "lost communication") is run again once, automatically, for that job only; a job that failed with a log, a job a person cancelled, and a second loss are not rerun, and the second loss fails the run with a message that says what happened.
- [ ] While the unit tests run, the job leaves a trace outside the runner that survives its loss: the time and the last test file reached, refreshed often enough to place the stop within a minute (for example a commit status the job updates).
- [ ] When both attempts of a job are lost at the same test file, the message says so, since that points to a hang of Appstein's own tests rather than the runner.
- [ ] The workflow gets no permission beyond what this needs, and the trace holds no secret.
- [ ] Tested: the rule that decides "lost, rerun once" on recorded job data (lost by limit, lost communication, failed with a log, cancelled by a person, second attempt), and the trace's text; proven once in a real run.
- [ ] The guide's CI page (`docs/guide/ci.md`) says how a lost job is handled and where its trace is.

## Comments

**2026-10-23, designed; the owner's answers.** A design helper (Opus high) found that GitHub runs a `workflow_run` workflow only from the default branch's copy of its file, and a run can't rerun its own jobs while it is still running. So the rerun is a second workflow that starts when CI ends, and the automatic rerun can be proven only once that workflow is on `main`. The owner decided (2026-10-23):

- **Route:** ticket 15 is built on its own branch from `main` and goes in as its own small pull request ahead of the slice. It is proven there, and `main` is then merged into `slice-1d7`.
- **A time limit reached with the runner alive** (Appstein's own hang, with a log) is not rerun, since its log shows where it hung. Only a job lost with no log (its steps unfinished) is rerun.
- **Two jobs lost in one attempt while another failed with a log:** nothing is rerun. The run prints the `gh run rerun --job` line for each lost job.
- **The trace** covers the `test` job's unit tests only, as a `CI trace / test (<system>)` commit status that shows on pull requests. The rule for what gets rerun covers every job.
