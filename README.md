# Appstein

A knowledge and verification layer for AI coding agents that build Flutter apps.

**Guide before. Check after.** Appstein gives agents such as Claude Code and Codex current, project-specific knowledge before they write code (generated from the installed Flutter SDK and the analyzed project), and a deterministic verifier after (analyzer, lint rules, native Android/iOS config audit, package gate, real builds) that blocks "done" until the work is correct.

> **Status:** pre-alpha. Milestone 1, slice 1a (workspace, CLI, SDK detection, `doctor`) is in progress. Start with the [developer guide](docs/guide/README.md).

## Read this first

| What | Where |
|---|---|
| Design spec (source of truth) | [`docs/superpowers/specs/2026-09-29-appstein-design.md`](docs/superpowers/specs/2026-09-29-appstein-design.md) |
| Visual summary of the spec | [`docs/superpowers/specs/2026-09-29-appstein-design.html`](docs/superpowers/specs/2026-09-29-appstein-design.html) (open in a browser) |
| Research behind it | [`docs/reports/`](docs/reports/) and [`docs/research_notes/`](docs/research_notes/) |
| Product and design context | [`PRODUCT.md`](PRODUCT.md), [`DESIGN.md`](DESIGN.md) |

## Roadmap

- **M1:** knowledge + verification foundation, in six slices (1a–1f).
- **M2:** a single-agent pipeline harness.
- **M3:** existing projects and more stacks.
- **M4:** a Flutter desktop app, multiple agents, every platform, then a web UI.

Details are in §18 of the spec.

## License

Not decided yet (see §22 of the spec). All rights reserved until then.
