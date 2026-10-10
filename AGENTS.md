# Appstein: guide for coding agents

Keep this file short. It holds only what you can't infer from the repo. Architecture lives in the spec, not here.

## What this repo is

Appstein is a Dart toolkit: a knowledge and verification layer for AI agents that build Flutter apps.

**Current phase:** M1. Where every milestone and slice stands, with its plan or spec and its pull request, is recorded in `docs/project/progress.yaml` and drawn at the top of the visual summary (below). What later slices inherit is listed under "Carried to later slices" in the slice 1a and 1b.1 plans, and in each finished slice's notes.

## Source of truth

- **Spec:** `docs/project/specs/2026-09-29-appstein-design.md` is the product design. If code and spec disagree, stop and ask the owner. Never silently "fix" the spec.
- **Slice specs:** each slice has a folder in `docs/project/slices/` with its own `spec.md`, one file per ticket and, once finished, `notes.md`. A slice's spec covers that slice only and cites the design sections it implements; build and review against it. Slices before 1d.2 have a plan in `docs/project/plans/` instead. Layout: `docs/agents/issue-tracker.md`.
- **Visual summary:** `docs/project/specs/2026-09-29-appstein-design.html` is a condensed companion. Whenever the spec changes, update it to match and re-check every claim on it against the spec.
- **Developer guide:** `docs/guide/` explains how the whole system works now, for humans (spec §19.6). Every source file is covered by a page (the `<!-- covers: -->` comment at its top). When you change code, update the pages that cover it, or add a `Docs-Checked: <page> - <reason>` commit trailer when a page is still right. Run `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`. See `docs/guide/docs-tooling.md`.
- **Progress:** `docs/project/progress.yaml` is the only place progress is written. When a slice's spec is committed, name its folder as the slice's `spec`; once the slice's PR is open, mark it done with its `pr` and `finished` date (in the same commit as the slice's `notes.md`) and mark the next slice `next`. Run `fvm dart run tool/gen_docs.dart` to redraw the visual summary. See `docs/guide/docs-tooling.md`.
- **Curated notes:** `notes/` holds the per-Flutter-version notes and the stores' build minimums (spec §6.4). They are owner-reviewed like spec text: never change a note's facts without the owner. After any edit, run `fvm dart run tool/gen_notes.dart`. See `docs/guide/how-to/add-a-curated-note.md`.
- **Knowledge graph:** when `graphify-out/GRAPH_REPORT.md` exists, read it before searching the repo. If a hook warned that the graph is behind, or you're starting a session after others changed the repo, run `tool/check_graph.py` with graphify's Python (see `docs/guide/docs-tooling.md`). Run `/graphify . --update` when it names new, changed or deleted docs; docs `missing from the graph` are put back from the cache by the hooks, or at once with `tool/check_graph.py --repair` (no LLM).

## Rules

- **Git:** read-only git commands are fine. Commit only with the owner's approval, and never push unless asked. Commits may include a `Co-Authored-By` trailer.
- **Per slice:** design interview → slice spec → tickets → build each ticket test-first → verify → docs → notes → owner review → commit. The owner approves the spec, then the ticket breakdown, before any code is written. The docs step means `///` comments on every public API, the `docs/guide/` pages for what the slice built, `gen_docs` and the guide check (spec §19.6), then `/graphify . --update` until `tool/check_graph.py` reports nothing, because the git hooks refresh only code structure; it must still report nothing when the slice merges. Never write guide pages for code that doesn't exist yet.
- **Windows is first-class** (the owner develops on Windows): paths with spaces, drive letters, PowerShell. Hooks call the `appstein` binary directly, with no bash scripts.
- **Never touch agent credentials**, and never encode Play Store or App Store policies (spec §2.3, §4).
- **Explain your reasoning.** The owner is learning to build large CLI tools.

## Agent skills

### Issue tracker

Specs and tickets are committed files, one folder per slice under `docs/project/slices/`. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: the product design and the developer guide today, `GLOSSARY.md` and `docs/adr/` once they exist. See `docs/agents/domain.md`.

## Environment gotchas

- **Flutter SDK:** the repo pins Flutter 3.47.5 in `.fvmrc`. Run every command through FVM (`fvm dart …`, `fvm flutter …`). The `dart` on your PATH may be an older SDK.
- **Git hooks:** run `fvm dart run tool/install_hooks.dart` once per clone, and again when `tool/src/hooks.dart` changes. It installs graphify's hooks (dev tooling: `uv tool install graphifyy`), graph rebuilds after merges and rebases, a post-commit docs warning, a warning when the graph lacks the current docs, and a background repair of docs a rebuild dropped from the graph.
