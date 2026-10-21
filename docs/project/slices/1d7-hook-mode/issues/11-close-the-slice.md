# Close the slice

**What to build:** the slice is checked as a whole, on a real app, through Claude Code's real hooks and by a second reader, and its records are complete: what was built, what was decided on the way, and what later slices inherit.

**Blocked by:** 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 12, 13.

Status: ready-for-agent

- [ ] The compiled binary is run on a copy of the fixture app with real packages, with the PostToolUse and Stop hooks written by hand into that copy's `.claude/settings.json` and a real Claude Code session: an edit that adds an error (blocked), a Bash command that changes nothing (silent), a warning (context), "done" with an error left (blocked, then the loop guard), and "done" when clean. Two sessions at once on the copy share one host. Every line of output is read, and anything wrong is fixed test first.
- [ ] Every new behaviour has a passing and a failing test (design §18).
- [ ] The repo's full check (`tool/test_all.dart`) is all green, the BOM scan is clean, and the numbers are written into the notes.
- [ ] No host, guard or analysis server is left running on the development machine after the tests and the end-to-end run.
- [ ] An independent review of the whole branch has been made, and the owner has decided what happens to each finding.
- [ ] `notes.md` is written: what was built, the rulings made during the work, where the process slipped, and what is carried to 1d.3, 1e and later slices.
- [ ] The developer guide covers every source file the slice added, `gen_docs` reports nothing to do, and the guide check passes.
- [ ] `/graphify . --update` has been run until `check_graph.py` reports nothing.
- [ ] Once the pull request is open, `progress.yaml` marks 1d.7 done with its `pr` and `finished` date in the same commit as `notes.md`, marks 1d.3 `next`, and the visual summary is redrawn and read back.
