# `--apply` renders the human docs

**What to build:** `appstein verify --full --apply` also renders the human docs into `docs/app/` when `docs.enabled` is on, so the Stop hook can be one command (design §5.3, §9.2). The order is: apply `dart fix`, format the project, bring the knowledge up to date, render the human docs, then run every check. The files rendered are named with the files rewritten.

**Blocked by:** None (can start immediately).

Status: resolved

- [x] On a project whose human docs are behind, a full run with `--apply` renders them, and the same run's `docs.stale` check finds nothing.
- [x] The docs are rendered after the fixes, the formatting and the knowledge refresh, with the same code as `appstein docs`, so the pages match what `appstein docs` would write.
- [x] Each page written is in the `applied` list of the JSON output and in the text output's list before the findings; a page that didn't change is not listed.
- [x] With `docs.enabled: false`, nothing is rendered and nothing is listed.
- [x] A docs render that can't be done (for example a person's file in the way) leaves that page alone and is reported by `docs.stale` as before; it is not Appstein failing.
- [x] Without `--apply`, nothing is written, as before.
- [x] The guide pages for the verifier and the human docs describe it; the guide check passes.

## Comments

**2026-10-17, built and reviewed.** Built by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), one fix round, then a short check (Opus high). The build was interrupted twice by the machine crashes of ticket 02's Unix-socket probe (not this work) and resumed from its files.

- **How it works.** `renderDocsForApply` calls `runDocs` (the code of `appstein docs`, not checking) after `applyToProject`, sharing one `KnowledgeSync` with the run: fix, format, knowledge refresh (`runDocs`'s first step), render, then every check. The pages written follow the Dart files in `applied`.
- **Fix round 1:** `cli.md`'s Verify steps described `--apply` without the docs; a hand-edited page was overwritten silently, against design §6.9 ("overwrites a hand-edited page and says that it did"), so each such page now gets a run notice ("Rendering the human docs overwrote hand edits in …"), which reaches the developer as a note; a mislabelled test split, with a page that is truly behind; a test that a page no longer rendered is not listed; wording.
- **Owner, 2026-10-17:** the `verify` tool of `appstein mcp` renders the docs with `apply` too (design §8 points to §9.2, and an agent with no Stop hook must be able to fix `docs.stale` itself). Same function, same order; the design's §8 row now says so.
- **Decided by Claude, not asked of the owner:** a hand-edited page is overwritten (with the notice), as `appstein docs` does; one person's file in the way refuses every page, because `appstein docs` "writes and removes nothing" then (the design's rule wins over this ticket's "leaves that page alone"); a page removed because no longer rendered is not listed; a docs write failure is Appstein failing (exit 3), and pages written before it part-way are not named.
- **Known limits, from the check:** with `apply`, a knowledge refresh error other than the expected ones now fails the tool call, as it already failed the terminal run; a busy knowledge lock can make an `apply` call wait a second 10 s inside the render. No MCP test of a refused render (the shared function's engine and CLI tests cover it).
- **Not verified:** Linux and macOS (CI will run them).
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 82, engine 1891 twice (8 skipped), CLI 205, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
