# Appstein: guide for coding agents

Keep this file short. It holds only what you can't infer from the repo. Architecture lives in the spec, not here.

## What this repo is

Appstein is a Dart toolkit: a knowledge and verification layer for AI agents that build Flutter apps.

**Current phase:** M1 slice 1a is being implemented (plan: docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md).

## Source of truth

- **Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. If code and spec disagree, stop and ask the owner. Never silently "fix" the spec.
- **Visual summary:** `docs/superpowers/specs/2026-09-29-appstein-design.html` is a condensed companion. Whenever the spec changes, update it to match and re-check every claim on it against the spec.
- **Developer guide:** `docs/guide/` explains how the code works now, for humans. Update the pages a change affects, and run `fvm dart run tool/check_guide.dart`.
- **Plans:** `docs/superpowers/plans/`, one per slice.
- **Knowledge graph:** when `graphify-out/GRAPH_REPORT.md` exists, read it before searching the repo.

## Rules

- **Git:** read-only git commands are fine. Commit only with the owner's approval, and never push unless asked. Commits may include a `Co-Authored-By` trailer.
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs → owner review → commit. The docs step means `///` comments on every public API, plus the `docs/guide/` pages for what the slice built (spec §19.6). Never write guide pages for code that doesn't exist yet.
- **Windows is first-class** (the owner develops on Windows): paths with spaces, drive letters, PowerShell. Hooks call the `appstein` binary directly, with no bash scripts.
- **Never touch agent credentials**, and never encode Play Store or App Store policies (spec §2.3, §4).
- **Explain your reasoning.** The owner is learning to build large CLI tools.

## Environment gotchas

- **Flutter SDK:** the repo pins Flutter 3.47.5 in `.fvmrc`. Run every command through FVM (`fvm dart …`, `fvm flutter …`). The `dart` on your PATH may be an older SDK.
- **graphify** is dev tooling only: `uv tool install graphifyy`. Its git hook rebuilds the graph on each commit.
