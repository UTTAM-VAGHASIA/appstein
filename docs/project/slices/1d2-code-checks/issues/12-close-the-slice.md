# Close the slice

**What to build:** the slice is checked as a whole, on a real app and by a second reader, and its records are complete: what was built, what was decided on the way, and what later slices inherit.

**Blocked by:** 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 13.

Status: ready-for-agent

- [ ] The compiled binary is run on a copy of the fixture app with real packages: a fast run, a full run, `--apply`, `--files`, both output formats, and the `verify` tool from Claude Code. Every line of output is read, and anything wrong is fixed test first.
- [ ] Every check of the slice has a passing and a failing fixture (design §18).
- [ ] The four test suites, the analyzer, the formatter, `dart doc --dry-run` in all four packages and the BOM scan are clean, and the numbers are written into the notes.
- [ ] An independent review of the whole branch has been made, and the owner has decided what happens to each finding.
- [ ] `notes.md` is written: what was built, the rulings made during the work, where the process slipped, and what is carried to 1d.7, 1d.3 and later slices.
- [ ] The developer guide covers every source file the slice added, `gen_docs` reports nothing to do, and the guide check passes.
- [ ] `/graphify . --update` has been run until `check_graph.py` reports nothing.
- [ ] Once the pull request is open, `progress.yaml` marks 1d.2 done with its `pr` and `finished` date in the same commit as `notes.md`, marks 1d.7 `next`, and the visual summary is redrawn and read back.
