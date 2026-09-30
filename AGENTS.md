# Appstein: guide for coding agents

Keep this file short. It holds only what you can't infer from the repo. Architecture lives in the spec, not here.

## What this repo is

Appstein is a Dart toolkit: a knowledge and verification layer for AI agents that build Flutter apps.

**Current phase:** M1 slices 1a, 1a.1, 1a.2 and 1b.1 are complete. 1a built the workspace, the CLI, `doctor` and CI (plan: docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md); its "Carried to later slices" section lists what 1b and 1d inherit. 1a.1 made the developer guide cover the whole system and stay current: the coverage map, the stale-page check, generated sections and hooks (plan: docs/superpowers/plans/2026-09-30-slice-1a1-docs-freshness.md). 1a.2 made the knowledge graph's freshness a checked state: `tool/check_graph.py` and a hook warning when the graph lacks the current docs (plan: docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md). Slice 1b is split into four sub-slices (1b.1 SDK lookup gaps, 1b.2 knowledge store + platform layer, 1b.3 project map, 1b.4 incremental sync + INDEX.md + package skills). 1b.1 made `doctor` agree with `flutter doctor -v` on every OS: build-tools and platforms, the aapt/adb fallback, macOS Android Studio discovery, FVM channel pins and cache, file error reasons, and a stricter stale-page rule (plan: docs/superpowers/plans/2026-09-30-slice-1b1-sdk-gaps.md). Next: plan slice 1b.2, the knowledge layer.

## Source of truth

- **Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. If code and spec disagree, stop and ask the owner. Never silently "fix" the spec.
- **Visual summary:** `docs/superpowers/specs/2026-09-29-appstein-design.html` is a condensed companion. Whenever the spec changes, update it to match and re-check every claim on it against the spec.
- **Developer guide:** `docs/guide/` explains how the whole system works now, for humans (spec §19.6). Every source file is covered by a page (the `<!-- covers: -->` comment at its top). When you change code, update the pages that cover it, or add a `Docs-Checked: <page> - <reason>` commit trailer when a page is still right. Run `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`. See `docs/guide/docs-tooling.md`.
- **Plans:** `docs/superpowers/plans/`, one per slice.
- **Knowledge graph:** when `graphify-out/GRAPH_REPORT.md` exists, read it before searching the repo. If a hook warned that the graph is behind, or you're starting a session after others changed the repo, run `tool/check_graph.py` with graphify's Python (see `docs/guide/docs-tooling.md`). Run `/graphify . --update` when it names new, changed or deleted docs; docs `missing from the graph` are put back from the cache by the hooks, or at once with `tool/check_graph.py --repair` (no LLM).

## Rules

- **Git:** read-only git commands are fine. Commit only with the owner's approval, and never push unless asked. Commits may include a `Co-Authored-By` trailer.
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs → owner review → commit. The docs step means `///` comments on every public API, the `docs/guide/` pages for what the slice built, `gen_docs` and the guide check (spec §19.6), then `/graphify . --update` until `tool/check_graph.py` reports nothing, because the git hooks refresh only code structure; it must still report nothing when the slice merges. Never write guide pages for code that doesn't exist yet.
- **Windows is first-class** (the owner develops on Windows): paths with spaces, drive letters, PowerShell. Hooks call the `appstein` binary directly, with no bash scripts.
- **Never touch agent credentials**, and never encode Play Store or App Store policies (spec §2.3, §4).
- **Explain your reasoning.** The owner is learning to build large CLI tools.

## Environment gotchas

- **Flutter SDK:** the repo pins Flutter 3.47.5 in `.fvmrc`. Run every command through FVM (`fvm dart …`, `fvm flutter …`). The `dart` on your PATH may be an older SDK.
- **Git hooks:** run `fvm dart run tool/install_hooks.dart` once per clone, and again when `tool/src/hooks.dart` changes. It installs graphify's hooks (dev tooling: `uv tool install graphifyy`), graph rebuilds after merges and rebases, a post-commit docs warning, a warning when the graph lacks the current docs, and a background repair of docs a rebuild dropped from the graph.
