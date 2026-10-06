# Appstein — Design Spec

| | |
|---|---|
| **Status** | Approved by the owner (2026-09-29) |
| **Date** | 2026-09-29 |
| **Owner** | UTTAM-VAGHASIA |
| **Supersedes** | FlutterCraft v0.1.x (Python CLI/TUI). The old repo is archived once the new repo exists (§20) |
| **Scope of this spec** | Full detail for Milestone 1 (M1); direction only for M2–M4, each of which gets its own spec |
| **Research basis** | `docs/reports/Flutter agentic harness landscape.md` and the 7 notes in `docs/research_notes/Flutter agentic harness landscape/` (deep research, 2026-09-28; written before the rename, so it still says "FlutterCraft") |
| **Visual companion** | `2026-09-29-appstein-design.html` (a condensed visual summary with diagrams, checked against this file; this Markdown file is the source of truth). Rejected design drafts are kept in `drafts/` |

---

## 1. Summary

Appstein is a **knowledge and verification layer for AI coding agents that build Flutter apps**. Coding agents such as Claude Code and Codex are already capable of building apps. What they lack is **accurate, current, project-specific context**, and a **reliable check** on their output. Without these, agents:

- write code for Flutter/Dart versions that are 8–11 releases old;
- burn tokens rediscovering the codebase every session;
- misconfigure native Android/iOS builds;
- add packages that don't exist or are abandoned.

Appstein fixes this in two ways:

1. **Guide before** the agent writes code. A generated, always-fresh knowledge layer (platform facts, a project map, decisions and memory) is served through files and an MCP server.
2. **Check after** the agent writes code. A deterministic verifier (analyzer, custom lint rules, native-config audit, package gate, real builds) blocks "done" until the work is correct.

The same knowledge is also rendered as **documentation for humans** (`docs/app/`, §6.9), so a developer can understand the app, or take over from the agent and code it themselves, without asking an agent first.

The owner's core belief drives the design. Models are already smart enough; **guided properly, they produce fewer bugs and spend fewer tokens**, because they no longer have to rediscover where everything is.

The long-term goal is a full agentic harness: first a single-agent pipeline, then a Flutter desktop app with a team of agents, then a web UI. That harness is **built on top of this foundation, not instead of it**.

### 1.1 Name and brand

- "Appstein" is a pun on "Einstein": *the Einstein of app development*. Spell it with **"-stein"**.
- Brand only on the Einstein pun, for example a messy-hair logo, a chalkboard style, or the line *"Apps = mc²"*. The name must never be tied to any other association in public material, README jokes or commit messages.
- **Never use Albert Einstein's name, image or signature.** His estate licenses and enforces them.
- Salesforce has an AI product called "Einstein"; keep our identity clearly separate.
- Run a trademark check and a domain check before the first published release (pub.dev or GitHub Releases). The public repo alone is not a release.
- Appstein is open source under the Apache License 2.0. A paid Pro tier may be added later as separate, closed code; whether to add one is decided after M1, when the benchmark results are known (§22).

---

## 2. Intent

### 2.1 Who it's for

- **Professional Flutter developers.** They want agents to work faster and with fewer errors, and they still review the code.
- **Beginners and "vibe coders."** They can't write Flutter code but want a real app they own that builds for the stores.

M1 mostly serves professionals; `create` gives beginners a correct starting point. Beginners are served fully once the guided harness exists (M2+).

### 2.2 What success looks like

- An agent working in an Appstein project **never leaves deprecated APIs** for the installed SDK in the final code.
- An agent **finds code through the map and MCP instead of searching**, and uses measurably fewer tokens.
- A project created by Appstein **builds for Android and iOS on the first try**, with correct native config and no toolchain conflicts.
- Knowledge **never goes stale**, because it is generated from the SDK and the code, and hand-written knowledge is checked.
- A developer who has never seen the project can **understand it from `docs/app/` alone**: what it does, where each part lives, how the parts connect and why it was built that way.
- Every one of these claims is **measured by the benchmark** (§17) and published.

### 2.3 Non-goals and out of scope for M1

| Item | Status |
|---|---|
| Encoding Play Store or App Store *policies* | Never. Appstein handles correct build and config only |
| Replacing Google's official tooling (`flutter/agent-plugins`, Dart MCP server) | Never. Appstein installs, pins and patches it and fills the gaps |
| Launching or driving agents | M2 |
| Existing projects (`appstein adopt`) | M3 |
| Riverpod and Bloc stacks | M3 (as packs) |
| Web, Windows, macOS and Linux as *target* platforms | M4+ (as packs) |
| Multi-package user projects (monorepos with several Flutter packages) | After M1. M1 supports one Flutter app package per project |
| Agents other than Claude Code and Codex (Cursor, Copilot, Antigravity, OpenCode) | After M1. Antigravity requires a terms review first |
| Gemini consumer subscriptions | Not viable: they no longer work in Gemini CLI since 2026-06-18 |
| Visual (golden/screenshot) verification and runtime app driving | M2 (§21) |
| Release builds, store upload, CI/CD pipelines for user apps | After M1. M1 does *static* release-readiness checks only |
| A browsable HTML docs site (`appstein docs --serve`) | After M1. M1 renders Markdown only (§6.9) |
| Hand-written or agent-written prose guides for user apps | Never as generated docs. Teams may keep their own notes next to them (§6.9) |

---

## 3. What the research changed (key facts)

Sources and links are in the research report. These facts shaped the design:

| Fact (as of Sept 2026) | Design consequence |
|---|---|
| Google's `flutter/agent-plugins` (v1.0.6) already installs 10 Flutter + 15 Dart skills, the Dart MCP server and format/analyze hooks into Claude Code, Codex, Cursor and Antigravity | We install and pin it rather than rebuild it. Wiring things up is not our advantage |
| The official Flutter skills are "happy path" only. They haven't changed since 2026-04-21, and `flutter-setup-localization` is broken on Flutter 3.47.2 (#239) | Our skills cover the gaps, override broken ones, and are **tested in CI** |
| The official plugin's rule is not auto-loaded by Claude Code or Codex | `integrate` copies the rule text into `CLAUDE.md` / `AGENTS.md` |
| Dart MCP server 1.1.2 is "experimental" and disables `dart_fix`, `dart_format`, `run_tests`, `create_project` and the app-lifecycle tools by default ("agents tend to do better just using the CLI"), while the official integration-test skill still calls `launch_app`. The official plugin already registers this server | Exactly **one** Dart MCP server runs (§11.1). Fix, format and tests are covered by our verifier and the CLI; the broken integration-test skill is overridden |
| The monolithic Flutter AI rules files were removed; Google now uses skills | We don't install rules files |
| `package:skills` 1.0 installs skills shipped inside packages (`dart run skills@ get`), but nothing re-runs it when `pubspec.yaml` changes (issue #585) | `sync` re-runs it when dependencies change (§6.6) |
| Deprecated-API use: deterministic replacement fixed more than 85% of cases, prompting alone was "not sufficient" (ICSE 2025). Top models solve only 48–51% of version-specific tasks (GitChameleon 2.0) | Guidance **plus** a deterministic post-edit gate |
| Current stable: Flutter 3.47.5 / Dart 3.13.4 (2026-09-18), quarterly releases. Material and Cupertino are moving into `material_ui` / `cupertino_ui`; the old imports are deprecated in the Nov 2026 stable | Version knowledge is generated per SDK, and an `upgrade` command applies migrations |
| New Dart syntax is gated by the project's language version (the pubspec SDK lower bound), not just the installed SDK | `sdk.json` records the language version and `delta.md` respects it |
| No tool checks native toolchain compatibility across a whole project. The SDK's `gradle_utils.dart` holds the matrix; iOS has no equivalent | The native-config audit is a core M1 feature; the iOS minimums come from curated notes |
| 2026 migrations: AGP 9 built-in Kotlin; SwiftPM default (3.44); CocoaPods trunk read-only 2026-12-02; UIScene required with Xcode 27; Play targetSdk 36 since 2026-08-31; 16 KB page size for apps targeting Android 15+ since 2025-11-01; iOS minimum 15 / macOS 12 in 3.47; Xcode 26 required for App Store uploads since 2026-04-28; AGP 9.4 not yet supported by Flutter | These become checks in the Android and iOS packs; agents are told never to "upgrade to latest" |
| Hard-coded SDK integers are the main way projects fall behind; keeping `flutter.compileSdkVersion` / `targetSdkVersion` / `minSdkVersion` keeps them current | `create` keeps the `flutter.*` variables; checks resolve them |
| `material_ui`'s compatibility bridge "cannot resolve type mismatches when a dependency exposes… in-framework SDK types" | `create` and `upgrade` switch to `material_ui` only when every dependency is compatible |
| Models invent package names in 5.2–21.7% of samples (USENIX Security 2025) | Package gate before any dependency is added |
| Pub advisories come from the GitHub Advisory Database (also in OSV); there is no official `dart pub audit` | The package gate reads advisories for the resolved versions |
| Dart 3.10 added first-party analyzer plugins; `custom_lint` is archived | Our architecture and design rules ship as analyzer rules that work in every agent and IDE |
| Anthropic allows only an end user logging in to the **unmodified** `claude` binary; no credential handling. `claude -p` runs a repo's hooks and MCP servers without a trust prompt. `--bare` will become the default for `-p` and ignores subscription login | Appstein never touches credentials. M2 spawns official CLIs only, with its own trust prompt and explicit flags |
| Free-form multi-agent setups cost about 15× the tokens; explicit pipelines with gates are better supported for coding | The M2 harness is a pipeline, not an "office" |
| Closest competitor: Vide (Flutter multi-agent, Claude-only, 114 stars). Munder Difflin's themed UI was called "too cute" on HN | Our edge is exact knowledge + verification + multi-agent support. The M4 UI is utilitarian |
| Flutter desktop terminal packages (`xterm`, `flutter_pty`) are effectively unmaintained | The M4 app renders structured agent events as native widgets; a raw terminal is only a fallback |

---

## 4. Design principles

1. **Generate, don't hand-write.** Platform and project knowledge is derived from the installed SDK and the analyzed code. Hand-written knowledge (decisions, memory, curated notes) is kept small and checked.
2. **Check, don't hope.** Every rule an agent is told should also be enforced by a deterministic check wherever possible.
3. **The engine knows no Flutter rules.** Flutter- or stack-specific knowledge lives only in **packs**. The engine is plumbing (learned from Twenty's `engine/` vs `modules/` split).
4. **One data format.** A single `protocol` package defines every model and JSON schema. The CLI, the MCP server, and the future desktop and web UIs all use it.
5. **A small context that is always loaded.** Only `INDEX.md` (at most 1,500 tokens) is always in context. Everything else is fetched on demand.
6. **Never touch credentials.** Appstein never reads, stores or relays agent login tokens.
7. **Irreversible steps need a human.** Application ID, bundle ID and signing keys always need explicit confirmation.
8. **Use our own product on our own repo.** Appstein's repo is checked by Appstein's own lint rules and boundary rules.
9. **Local first, private by default.** No telemetry. The only network calls are to pub.dev and advisory data for package checks, and to optional integrations the user enables (§16).
10. **Windows is first-class.** The owner develops on Windows; paths with spaces, drive letters and PowerShell or cmd shells must all work. Hooks call the `appstein` binary directly, with no bash dependency.
11. **One source, two audiences.** Agents read `.appstein/` (compact, machine-shaped); humans read `docs/app/` (explained, diagrammed). Both are rendered from the same knowledge, so they can never disagree. The same holds for Appstein's own repo: the graph serves agents, the developer guide serves humans (§19.6).

---

## 5. Architecture

### 5.1 Repository layout (Dart pub workspace)

```
appstein/                         ← one git repo, Dart pub workspace (Dart ≥ 3.6 feature)
├── packages/
│   ├── appstein_protocol/        models + JSON schemas (Finding, Feature, Route, Knowledge…)
│   ├── appstein_engine/          SDK detection, knowledge store, check runner, MCP server
│   │   └── lib/src/packs/        official_mvvm/, android/, ios/  (folders for now)
│   ├── appstein_cli/             the `appstein` command — thin layer over the engine
│   └── appstein_lints/           analyzer plugin: our lint rules, one test file per rule
├── skills/                       lifecycle skills (source) + CI that analyzes their code snippets
├── notes/                        curated per-Flutter-version notes (§6.4) — small, reviewed
├── benchmark/                    eval tasks, fixture apps, runner, results
├── docs/                         specs, plans, research (moved from the old repo)
│   └── guide/                    developer guide for humans working on Appstein (§19.6)
├── .github/workflows/            CI (§19.3)
├── AGENTS.md  CLAUDE.md  .mcp.json
└── graphify-out/                 graphify knowledge graph of this repo (dev tooling, §19.1)
```

**Boundary rules**, enforced by `appstein_lints` on our own repo:

- `protocol` depends on nothing internal.
- `engine` depends only on `protocol`.
- `cli` depends on `engine` and `protocol`.
- `lints` depends only on `protocol`. It never imports packs. Stack packs export their layer rules into the project's `analysis_options.yaml` (a top-level `appstein_lints:` section, written by `create`/`integrate`/`sync`), and the lints read them from there (§9.6).
- Packs never import each other.
- The engine core never imports a pack. Packs are registered through the pack interface (§10).

Packs start as folders because 4 packages are enough complexity for now. They become separate packages when community packs arrive (M3+).

### 5.2 Engine components

| Component | Responsibility |
|---|---|
| `sdk/` | Detect Flutter/Dart version and channel (FVM-aware: `.fvmrc` / `.fvm/`) and the project's Dart language version (pubspec SDK lower bound) |
| `toolchain/` | Read the SDK's own toolchain data for `toolchain.json` (§12): `packages/flutter_tools/lib/src/android/gradle_utils.dart`, the Gradle plugin's build checks and the Xcode template |
| `notes/` | Parse the curated notes and the stores' build minimums, compiled into the binary (§6.4) |
| `delta/` | Build the version delta (§6.4) from what the project's imports expose, the `fix_data` migrations of the SDKs and packages, and the curated notes |
| `config/` | Load and validate `appstein.yaml` (§7) |
| `project/` | Find the project's root folder |
| `host/` | The machine Appstein runs on: environment variables, finding and running programs, file errors and links |
| `android/` | Find the Android SDK and the JDK the way Flutter does, for `doctor` |
| `doctor/` | The `doctor` checks (§5.3) |
| `knowledge/` | Run generators (from packs), write `.appstein/`, hold freshness metadata, take the write lock (§15) |
| `map/` | Analyze the project's Dart code once, with the analyzer cache, and write the map files the packs' extractors produce (§6.5) |
| `native/` | Write `native.json` from the platform packs' extractors (§6.5) |
| `index/` | Build `INDEX.md` (§6.3) |
| `skills/` | Run package:skills when dependencies change (§6.6) |
| `text/` | Text helpers, such as edit distance |
| `verify/` | Run checks (from packs + core), apply suppressions and severity overrides, produce findings |
| `mcp/` | MCP server (using `package:dart_mcp`) exposing knowledge and verify tools |
| `docs/` | Render human documentation (`docs/app/`) from the knowledge layer, using page contributions from packs (§6.9) |
| `integrate/` | Install and configure agent integrations (Claude Code, Codex) |
| `create/` | New-project flow |
| `upgrade/` | Versioned migrations for user projects and for the `.appstein/` format |
| `packs/` | The pack interface and the built-in packs. Packs contribute extractors, checks, layer rules, skills, templates and migrations. The CLI registers the packs a project's `appstein.yaml` names |

### 5.3 Commands

| Command | Purpose |
|---|---|
| `appstein create <name>` | New project with the right structure, tokens and native config, plus knowledge and agent setup; must pass `verify` (§13.1) |
| `appstein sync [--detect]` | Regenerate knowledge. A plain `sync` rebuilds everything; `--detect` compares content hashes with `state.json` and rebuilds only when an input changed (§5.4) |
| `appstein verify [--fast\|--full] [--format json\|text] [--hook claude\|codex] [--files <…>]` | Run checks; exit codes in §9.5 |
| `appstein mcp` | Start the MCP server over stdio (launched by agents) |
| `appstein docs [--check]` | Render the human docs into `docs/app/` (§6.9); `--check` writes nothing and exits 1 if the docs are stale |
| `appstein upgrade [--dry-run]` | Apply versioned migrations after an SDK or Appstein upgrade (§13.2) |
| `appstein integrate [claude\|codex\|all] [--remove]` | (Re)install or remove agent integration in the current project |
| `appstein doctor` | Check the environment and explain fixes. Checks: Flutter, Dart, FVM, **the JDK Flutter actually uses** (`flutter config --jdk-dir`, `JAVA_HOME` vs Android Studio's bundled JBR), Android SDK + build-tools (incl. `zipalign`), Xcode ≥ 26 + CocoaPods on macOS, git, ripgrep (needed by the Dart MCP server's `rip_grep_packages`), agent CLIs, and that `appstein` is on the PATH that agent hook shells see (Windows) |
| `appstein --version` | Appstein version, protocol version, supported Flutter range |

All commands accept `--project <path>` (default: the current directory, or the nearest parent containing `pubspec.yaml`).

### 5.4 Runtime flow

```
session starts
  └─ SessionStart hook → `appstein sync` (creates or refreshes .appstein/, incl. INDEX.md)

agent changes files (Edit / Write / MultiEdit, or a Bash command such as `flutter pub add`)
  └─ PostToolUse hook → `appstein sync --detect` → `appstein verify --fast --hook <agent>`
       │   (--detect finds changed files by comparing content hashes with state.json,
       │    so changes made through Bash are caught too. When nothing the knowledge
       │    reads changed, it stops there; otherwise it rebuilds, with the analyzer
       │    cache (§6.2). It records the changed files in state.json for verify --fast)
       ├─ pass → continue
       └─ findings → fed back to the agent (file:line, message, fix hint, knowledge ref)
          NOTE: fast checks only REPORT. They never rewrite files mid-session,
          because rewriting a file the agent just read makes its next edit fail.

dependencies changed (pubspec.yaml / pubspec.lock)
  └─ same hook → package gate + re-run `dart run skills@ get` (package skills)

agent needs context
  └─ MCP: overview / where_is / feature / check_api / toolchain / package_check …

agent says "done"
  └─ Stop hook → `dart fix --apply` + `dart format` (safe now) → `appstein docs` (human docs, §6.9)
       → `appstein verify --full --hook <agent>`
       ├─ pass → task may end
       └─ errors → "done" is blocked; findings are fed back
          Loop guard: if Claude reports `stop_hook_active` and the same errors have blocked
          3 times in a row, Appstein stops blocking, lets the agent end, and prints the
          remaining errors for the user instead of burning tokens in a loop.
```

For agents without a SessionStart hook (Codex, until verified), `AGENTS.md` instructs the agent to call the `overview` MCP tool first. That tool syncs if the knowledge is missing or stale.

---

## 6. Knowledge layer

### 6.1 The four layers

| Layer | Contents | Source | Freshness |
|---|---|---|---|
| **1. Platform** | SDK facts, version delta ("use X, not Y"), toolchain matrix | Generated from the installed SDK plus Appstein's curated notes (§6.4) | Rebuilt when the SDK version changes; the delta also when the project's imports or packages change |
| **2. Project map** | Features, files, routes, layers, dependencies, native config | Generated by the Dart analyzer plus pack extractors | Rebuilt incrementally after every edit |
| **3. Decisions** | Architecture choice, state management, design tokens, conventions, with the reason for each | Written by the user or agents (MCP `record_decision`) | Checked against the code by the verifier |
| **4. Memory** | Current task, what was tried, lessons learned | Written by agents (MCP `memory_write`) | Tidied up when a task finishes |

### 6.2 The `.appstein/` folder

```
.appstein/
├── INDEX.md               (generated, git-ignored) always-loaded entry point (≤ 1,500 tokens, enforced by test)
├── state.json             (generated, git-ignored) input hash per source file, hash of each written file, last changes, last sync
├── .lock                  (git-ignored) the write lock (§15)
├── platform/   (generated, git-ignored)
│   ├── sdk.json           {flutter, dart, channel, languageVersion, fvm, appsteinNotesCoverage}
│   ├── delta.md           version delta for THIS SDK, language version and packages (§6.4)
│   ├── delta.json         the same delta as structured data, for check_api and what_changed
│   └── toolchain.json     valid AGP/Gradle/KGP/JDK/NDK/compileSdk/targetSdk/minSdk + iOS/macOS minimums
├── map/        (generated, git-ignored)
│   ├── features.json      feature → screens, view models, repositories, services, models, tests, files
│   ├── symbols.json       public classes/functions → file, layer, feature (index for where_is)
│   ├── routes.json        path → screen, with an "unresolved" flag for dynamic routes
│   ├── layers.json        layer tags per file + import edges + violations
│   ├── deps.json          package → version, usages, health snapshot, advisories
│   └── native.json        Android + iOS config state (versions, ids, permissions, manifests)
├── decisions/  (written, committed)   NNNN-<slug>.md (§6.7)
└── memory/     (written, committed)   current.md, lessons.md (§6.8)
```

- **Every generated knowledge file** (`INDEX.md`, `platform/`, `map/`) **carries** `generatedAt`, `appsteinVersion`, `formatVersion`, `sdkVersion` and a hash of its inputs. JSON files carry it in a `meta` key, Markdown files in a YAML front-matter block at the top. This makes staleness detectable: `verify` fails with `knowledge.stale` if a hash doesn't match. `state.json` is Appstein's own record of the last sync: of these fields it carries only `formatVersion` and `appsteinVersion`, and it has no `meta` key.
- **A generated file is rewritten only when its content would change:** Appstein rebuilds it with the `generatedAt` already in the file and compares the bytes. So syncing unchanged inputs changes no bytes, `generatedAt` included, and a hand-edited file is put back (§15).
- **`INDEX.md` is generated too.** `AGENTS.md` / `CLAUDE.md` point to it. On a fresh clone it is created by the SessionStart hook, or by the `overview` MCP tool for agents without that hook (§5.4).
- **The analyzer cache isn't knowledge.** `sync` keeps the Dart analyzer's work in `.dart_tool/appstein/`, where Dart tools keep their caches (Flutter's template already git-ignores `.dart_tool/`, and `flutter clean` deletes it). It only makes syncs faster: deleting it, or a damaged one, costs one slow sync and never changes the knowledge. The package skills record (§6.6) lives there too; deleting it costs one extra package skills run.

**Git policy for everything Appstein touches in a project:**

| Path | Committed? | Why |
|---|---|---|
| `.appstein/INDEX.md`, `platform/`, `map/`, `state.json`, `.lock` | No (git-ignored) | Generated; no merge conflicts; can never be committed stale |
| `.appstein/decisions/`, `.appstein/memory/` | Yes | Hand-written project knowledge |
| `appstein.yaml`, `analysis_options.yaml` | Yes | Project configuration |
| `docs/app/` (human docs, §6.9) | Yes | A **deliberate exception** to "generated = git-ignored": humans must be able to read the docs on GitHub or in a clone without Appstein. The output is byte-identical for the same inputs, so it only changes when the app does, and the `docs.stale` check catches docs that fall behind |
| `.mcp.json`, `.claude/settings.json`, `.claude/skills/`, `.agents/skills/`, `.config/dart_skills`, the Appstein-managed blocks in `CLAUDE.md` / `AGENTS.md` | Yes | Every teammate and every clone gets the same agent setup; `integrate` regenerates them deterministically from `appstein.yaml`. package:skills requires `.config/dart_skills` to be committed together with the agent skill folders |

`integrate` writes the `.gitignore` entries.

### 6.3 `INDEX.md` template (generated)

1. **Project**: name (from `pubspec.yaml`), app/bundle IDs (from `native.json`; one per Xcode configuration when they differ; an `unknown` ID says so and points to `native.json`, never a guess), target platforms (the platform folders that exist, as Flutter decides), stack pack, Flutter/Dart/language version.
2. **Rules that matter most**: "ask Appstein MCP before searching", "run verify before claiming done", "never upgrade native toolchain versions yourself; use `toolchain()`", and dependency policy in one line. A rule names an MCP tool only when this Appstein version offers it; the same holds for the pointers below, which name the file until the tool exists.
3. **Features**: a table of feature → screen count → main files (top 15, most screens first; "…and N more, use `feature()`"). When the map was skipped, the section says why.
4. **Where things live**: layer → folder, from the stack pack's layer rules.
5. **Version notes**: the 5–10 highest-priority curated notes in `delta.md`'s order, a count of the deprecated, removed and changed APIs and the moved libraries `delta.md` lists, and a pointer to `what_changed()`.
6. **Decisions**: one line per accepted or proposed decision with a link; superseded ones are left out, and one whose front matter can't be read is listed as unreadable.
7. **Current work**: the first lines of `memory/current.md` (at most 10), or "none recorded yet".
8. **Freshness**: SDK, Appstein version, and "notes may be incomplete" if applicable. The generated time is the front matter's `generatedAt` (§6.2), so the body has no timestamp and an unchanged project changes no bytes.

**The budget** is measured as the file's UTF-8 bytes ÷ 3, so 1,500 tokens is at most 4,500 bytes. Each model tokenizes differently and none of their tokenizers is available offline; dividing by 3 overestimates for code-heavy Markdown, so the real count stays under 1,500. If the budget would be exceeded, lower-priority sections are truncated in this order, each with a pointer to the MCP tool that holds the full data: version notes down to 5 (`what_changed()`), then current work (`memory_read()`), then decisions (`decisions()`), then features down to 5 rows (`feature()`). Only if the text still doesn't fit are features, then version notes, cut below 5. The generic notes go first because the project's own decisions and current work exist nowhere else in view. Project, rules, where things live and freshness are never cut. A test proves that a very large project still fits.

### 6.4 The version delta (`delta.md`) and curated notes

`delta.md` is built from three sources:

- **Deprecations:** `@Deprecated` annotations, with their messages, in every library the project's imports expose: Flutter's, the `dart:` libraries' and the packages'. A deprecation kind such as `@Deprecated.implement` forbids only that one use.
- **Migrations:** the `fix_data.yaml` and `fix_data/**.yaml` files of the Flutter SDK, the Dart SDK and each package (the files `dart fix` reads), including APIs since removed, with their replacements. A migrated API is listed as `removed` (gone; code that uses it doesn't compile) or `changed` (it still exists, and the migration changes how it is used), with its migration's title. `delta.md` also lists the libraries a migration moves elsewhere, and any migration file Appstein couldn't read.
- **Appstein's curated notes** in `notes/<flutter-minor>.yaml`, one per stable Flutter minor version, for changes the above can't express, e.g. "new projects use `material_ui`", "dot shorthands available when language version ≥ 3.10", "iOS minimum 15". The file for the oldest supported minor also holds the notes from the baseline up to it. Each file records the minor's first stable release date and Dart version, the toolchain matrix used as a fallback (§12), and its notes. Each note has an `id`, `since`, `languageVersion` (optional), `priority` (1–3), `area` (`framework`, `dart`, `android`, `ios` or `tooling`), `summary`, `use`, `avoid`, and `source` (a URL to official docs). Store-imposed build minimums (the Play target API, the Xcode version for App Store uploads) change on the stores' schedule, not Flutter's, so they live in `notes/stores.yaml`, each with the date it applies from and its source. The notes are compiled into the `appstein` binary, so reading them needs no network.

Other rules for the delta:

- **Baseline:** configurable (§7). It limits the curated notes: the default covers notes since **Flutter 3.16**, so it includes the 3.16 changes models still get wrong (`WillPopScope`→`PopScope`, `textScaleFactor`→`TextScaler`, Material 3 on by default). Deprecations and migrations are included whatever their age. Anything the installed SDK or a package still marks fails `verify` (§9.1), and neither a deprecation message (`deprecated after v3.12.0-1.0.pre` first shipped in stable 3.16) nor a `fix_data` date reliably names the stable release a change shipped in.
- **Filtering:** deprecations and migrations are filtered to what the project's imports expose (the analyzer's export namespaces), leaving out the project's own code. Every note since the baseline is included. Notes that need a newer language version than the project's are listed separately. When the map is skipped (§6.5), the delta holds only the notes and says why.
- **Ranking:** notes by curated priority first, then by how often the benchmark sees agents hit them (recorded in the notes after each benchmark run); deprecations and migrations by package, then name.
- **Coverage:** if the installed SDK is newer than the newest note, `sdk.json.appsteinNotesCoverage` is `partial` and the delta, INDEX and `verify` say "notes may be incomplete for X.Y". Everything generated from the SDK still works.

### 6.5 The project map (official_mvvm pack)

Extraction uses the **resolved** Dart AST from `package:analyzer`, not text search.

- **Resolution:** resolving needs the project's packages, so `sync` checks them the way `flutter run` and `flutter analyze` do.
  - It skips `pub get` only when `.dart_tool/package_config.json` and `pubspec.lock` exist, `pubspec.yaml` is older than both, and `.dart_tool/version` names this Flutter version.
  - In a pub workspace, the package config is found through `.dart_tool/pub/workspace_ref.json`. A package config written by another tool is used as it is.
  - Otherwise it runs `flutter pub get` with the project's SDK. If that fails (for example, offline with nothing cached), `sync` still writes the platform layer and `native.json`, skips the rest of the map, and says why and what to run.
  - Code with errors still gets a map: the analyzer resolves what it can.
- **Layer tags by path:**
  - `lib/ui/**` → `ui`
  - `lib/data/repositories/**` → `data.repository`
  - `lib/data/services/**` → `data.service`
  - `lib/data/model/**` → `data.model` (API models, in Flutter's architecture guide)
  - `lib/domain/**` → `domain`
  - `lib/routing/**` → `routing`
  - `lib/config/**` → `config`
  - `lib/utils/**` → `utils`
  - `test/**` and `testing/**` (shared fakes) → `test`
- **Features:** each folder under `lib/ui/` that has a `view_models/` or `widgets/` folder, named by its path below `lib/ui/`. So `lib/ui/auth/login/` is the feature `auth/login`. `lib/ui/core/` holds the UI that features share (widgets, themes, localization), so it is not a feature. A feature lists:
  - **view models:** the concrete classes in its `view_models/` that extend `ChangeNotifier`, directly or through other classes (an abstract base class is not a view model);
  - **screens:** the widgets in its `widgets/` that routes build. Without routes, no widget is called a screen; screens are never guessed from names;
  - **repositories and services:** the types its view models' constructors take, sorted by the layer of the file that declares each type;
  - **models:** the public classes in `domain` files that the feature's files import, except use cases (`lib/domain/use_cases/`);
  - **tests and files:** its tests under `test/ui/<feature>/`, and all of its files.
- **Symbols:** public top-level classes, mixins, enums, extensions, extension types, typedefs and functions in `lib/`. Each has its file, line, layer, feature and **summary**: the first sentence of the first paragraph of its `///` doc comment, if it has one. The summary feeds the human docs (§6.9) and gives `where_is` results a one-line description.
- **Routes:** `GoRoute(path:, builder:/pageBuilder:)` entries reachable from every `GoRouter(...)` in `lib/`.
  - They include nested routes and the routes inside `ShellRoute` and `StatefulShellRoute`.
  - A nested path is joined to its parent's, as GoRouter does. Constant paths are evaluated (`Routes.home`, `'/$searchRelative'`).
  - The screen is the widget the builder returns (for `pageBuilder`, the page's `child:`), when the builder is a single plain return.
  - Only paths and builders that are statically resolvable are recorded; anything else is marked `unresolved` and never guessed.
  - Typed routes (`go_router_builder`) are recorded as one unresolved entry until a later slice reads them.
- **Layers:** each file's tag, its imports of other project files, and the imports that the pack's layer rules forbid (§9.6). So `layers.json` reports exactly what `layer_imports` reports.
- **Dependencies:** `pubspec.yaml`, `pubspec.lock` and import usages per package. The health snapshot and advisories from the last package check are added once the package gate exists (§9.4).
- **Native config** (from the platform packs, `map/native.json`). The packs read the native files directly, without the Dart analysis, so `native.json` has its own input hash and is written even when the rest of the map is skipped.
  - Android: `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/app/build.gradle.kts`, `gradle-wrapper.properties`, the listed keys of `gradle.properties` (`android.builtInKotlin`, `android.newDsl`, `android.useAndroidX`, `kotlin.*`), and the main, debug and profile `AndroidManifest.xml`. Groovy build files (`build.gradle`, from projects created before Flutter 3.29) aren't read yet; their values are recorded as `unknown` with that reason.
  - iOS: `Info.plist`; the `project.pbxproj` build settings of the Runner target, per configuration; the `Podfile` when present; the `Package.swift` that `flutter pub get` generates; and the Flutter SwiftPM setting, decided as Flutter decides it (the `pubspec.yaml` `flutter: config:`, then the global `flutter config`, then `FLUTTER_SWIFT_PACKAGE_MANAGER`, then the version's default), with where it came from.
  - Each value is `found` (with its file:line), `unknown` (computed in Gradle code, set more than once, set conditionally, or unreadable, with the reason) or `absent`. Nothing is guessed. A value written as one of Flutter's variables (`flutter.minSdkVersion`) records the expression and the number it resolves to with the installed SDK.
  - Secrets are never recorded: signing configs by name only, no passwords or keystore paths, only the listed `gradle.properties` keys, and only whether an Xcode development team is set.

### 6.6 Package skills

When `pubspec.yaml` or `pubspec.lock` changes, `sync` runs `package:skills` for the project's agents. This installs skills that packages ship themselves, so agents get the API for the **installed** version of each package.

- **The command:** `dart run skills@<pinned> -C <project> get --all --agent <agent>…`, using the `dart` of the project's own Flutter SDK, after the knowledge is written (so after any `flutter pub get` sync ran, whose package config package:skills reads). The version is pinned exactly and moves with Appstein releases. `--all` is needed because without a terminal `get` installs nothing; it recopies every skill package:skills manages, so local edits to those skills are overwritten.
- **The agents:** those in `integrations.agents` (§7) that are already set up in the project: Claude Code when `.claude/` exists (skills go to `.claude/skills/`), Codex when `.agents/` or `AGENTS.md` exists (`.agents/skills/`). `sync` never creates an agent's folder; when no agent is set up, it says so in one line and runs nothing.
- **When it runs:** `.dart_tool/appstein/package_skills.json` records the hashes of `pubspec.yaml` and `pubspec.lock`, the agents and the pinned version from the last run, and whether it succeeded. A run happens when any of them differ or there is no record. Two syncs never run it at once: a sync that finds another one running it skips it.
- **Failures are warnings:** package:skills exits 0 on most errors, so success is judged from its output too. A failure, or a run longer than 120 s (it is stopped), is a warning; `sync` continues and the knowledge is unaffected. A full `sync` retries a failed run; `sync --detect` retries only when the inputs above change again, so being offline doesn't slow every edit.
- **Outside the project:** package:skills keeps its own state in `dart_skills/global_config.json` in the user's application-data folder (`%APPDATA%` on Windows) and rewrites it on every run that installs anything. It is that tool's own bookkeeping, not agent config or credentials, and package:skills offers no way to skip it. It also sends the package names and versions to osv.dev to check for advisories, and `--all` also installs skills from git repositories the user listed in that file or in the project's `.config/dart_skills/`.

### 6.7 Decision record format

```markdown
---
id: 0002
title: State management with provider + ChangeNotifier
status: accepted          # proposed | accepted | superseded
date: 2026-10-02
supersedes: null
paths: [lib/ui/**/view_models/**, lib/config/dependencies.dart]
checks: [stack.provider]  # optional: verifier checks that confirm this decision
---
Why: Flutter's architecture guide recommends it; one stack pack keeps checks exact.
```

The verifier checks every accepted decision that lists `checks`. In M1 the built-in decision checks are:

- `stack.provider`: the detected state management matches.
- `paths.exist`: listed paths still match files.

A mismatch is reported as a `decision.drift` warning.

### 6.8 Memory format

- **`memory/current.md`**: the task in progress (goal, plan, status, open questions). `memory_write` with `kind: current` replaces it.
- **`memory/lessons.md`**: dated one-line lessons, e.g. "2026-10-03: plugin X needs minSdk 26". `memory_write` with `kind: lesson` appends.
- **Finishing a task:** `memory_write` with `kind: complete` moves a one-paragraph summary of `current.md` into `lessons.md` and clears `current.md`.
- **Size limits:** `lessons.md` over 200 lines produces an info finding suggesting consolidation. Nothing is deleted automatically.

### 6.9 Human documentation (`docs/app/`)

Everything above is shaped for agents: compact, machine-readable and git-ignored. People need the same knowledge in a different form, for the day a developer reads the code, reviews it, or takes over from the agent and codes it themselves. Appstein **renders** the knowledge layer into readable Markdown for them. Nothing is written just for the docs, so they follow principle 1 (generate, don't hand-write) and principle 11 (one source, two audiences).

**Pages** (in `docs.path`, default `docs/app/`):

| Page | Contents | Rendered by |
|---|---|---|
| `README.md` | What the app is: name, app/bundle IDs, target platforms, stack pack, Flutter/Dart/language version, how to run it, and an index of every page (including team notes, below) | engine |
| `architecture.md` | The stack's layers in plain language (what a view model, repository and service each do), a Mermaid diagram of which layer may use which (from the pack's layer rules, §9.6), and a folder → layer table | stack pack |
| `features/<feature>.md` | One page per feature: screens → view models → repositories → services as a Mermaid diagram and a table, the feature's routes and tests, and the doc-comment summary of each class | stack pack |
| `routes.md` | The route tree, with dynamic routes marked "unresolved" (never guessed, §6.5) | stack pack |
| `native.md` | Android and iOS setup: IDs, SDK levels, toolchain versions, and every permission with the plugin that needs it, each value with its file:line | platform packs |
| `dependencies.md` | Each package: version, where it is used, and its last package-gate verdict (§9.4) | engine |
| `decisions.md` | Every accepted decision with its "Why", linking to the record in `.appstein/decisions/`; superseded decisions listed separately | engine |

GitHub renders Mermaid diagrams natively, so the pages need no extra tooling to read.

**Where the prose comes from:**

- **Concept explanations** ("what is a view model?", "why SDK levels use `flutter.*` variables") are written **once, by Appstein, inside each pack**, and are versioned with the pack. They are not per-project text.
- **Project-specific explanations** come from two places that already exist:
  - the "Why" in each decision record (§6.7);
  - `///` doc comments on public classes. The `document_public_classes` lint (§9.6) requires them in the layers the docs render, and the map stores each one's first sentence as the symbol's summary (§6.5).

**When the docs are rendered:**

- `create` renders the first set (§13.1).
- The Stop hook renders them once per task, after `dart fix` and `dart format` and before the full verify (§5.4). Rendering per task, not per edit, keeps the working tree quiet while the agent works.
- `appstein docs` renders them on demand, e.g. after a human edits code without Appstein.
- If `docs.enabled` is `false`, nothing is rendered and `docs.stale` doesn't run.

**Staying correct:**

- **Deterministic output.** Each page starts with an Appstein-managed marker holding the Appstein version, a hash of the page's inputs and a hash of the rendered body. There is **no timestamp in the body**, so re-rendering unchanged knowledge produces no git diff. An Appstein upgrade that changes the templates produces a single one-time diff.
- **`docs.stale`** (in `verify --full`, §9.2) re-computes each page's input hash and reports pages that fell behind. It is a **warning** by default: blocking a human's CI over docs would punish exactly the people the docs are for. Teams that want it enforced raise it to an error with `verify.severity`.
- **Merge conflicts** in generated pages are resolved by re-running `appstein docs` after the code conflict is resolved, because the output depends only on the code and knowledge.

**Hand edits and team notes:**

- Generated pages carry the marker and say "Generated by Appstein; edits are overwritten".
- `docs.stale` also reports a generated page whose body no longer matches the body hash in its marker (it was hand-edited) as a warning, suggesting the text be moved into a team note.
- **Any file in `docs/app/` without the marker is never touched.** Teams keep their own notes there (onboarding steps, runbooks), and `README.md` lists them under "Team notes".
- The Appstein-managed block in `CLAUDE.md` / `AGENTS.md` tells agents never to edit generated docs (§11.1).

**Not in M1:** a browsable HTML site with search (`appstein docs --serve`) can be layered on the same Markdown later (§2.3).

---

## 7. Project configuration: `appstein.yaml`

`create` and `integrate` write this file at the project root, and it is committed:

```yaml
appstein: 1                      # config format version
packs:
  stack: official_mvvm
  platforms: [android, ios]
delta:
  baseline: "3.16"               # curated notes since this Flutter version (§6.4)
verify:
  fast_timeout_seconds: 20       # safety cap; the target is < 5 s (§15)
  build_on_full: true            # run real debug builds in --full
  severity:                      # per-check overrides
    ui.no_hardcoded_colors: warning
docs:
  enabled: true                  # render human docs (§6.9)
  path: docs/app                 # relative to the project root
packages:
  stale_after_months: 12
  allow: []                      # packages exempt from the maintenance warning
  deny: []                       # packages that are always blocked
integrations:
  agents: [claude, codex]
  graphify_export: false         # optional (§16)
  developer_knowledge_mcp: false # optional (§16), needs a Google Cloud API key
```

Unknown keys are an error with a clear message. Every key has a default, so an empty file is valid.

---

## 8. MCP server

Transport is stdio; `appstein mcp` is launched by the agent. Every tool returns structured JSON (schemas in `appstein_protocol`) and a short text summary.

**Freshness.** Before each tool answers, the server runs the check `sync --detect` runs, in its own process, keeping the analyzer cache in memory between calls:

- nothing changed: it answers from the files;
- an input changed: it rebuilds what changed first (target < 2 s);
- `.appstein/` is missing (a fresh clone, or an agent without a SessionStart hook): it runs a full sync first;
- it never runs package skills (§6.6), which can take up to 120 s; the next `appstein sync` runs them.

Every reply has a `freshness` field: `current`, `rebuilt` (with what changed) or `stale` (with why). When another sync holds the lock past its timeout, or the sync fails, the server answers from the files on disk marked `stale`, with the reason and, when it helps, "run `appstein doctor`". With no knowledge files at all, the reply is an error.

**Errors.** Bad input, a failed sync with nothing to answer from, and a tool that throws each give a tool result marked as an error, with the reason, and the server keeps running. An error reply has no structured content; it states the freshness in its text. Arguments that don't fit a tool's input schema are refused before the tool runs, so that reply has no freshness. Only protocol messages go to stdout.

| Tool | Input | Returns |
|---|---|---|
| `overview` | – | Contents of INDEX.md plus live freshness status |
| `where_is` | free text (e.g. "login screen") | Ranked files and symbols with layer and feature |
| `feature` | feature name | Everything in that feature: screens, view models, repositories, services, models, routes, tests |
| `route` | path; a concrete path matches a pattern (`/book/42` → `/book/:id`) | Screen, feature, parent, nested routes, and whether it redirects (the map records that a route redirects, not where to) |
| `check_api` | a name: `WillPopScope`, `withOpacity`, `Color.withOpacity`, `Text.new(textScaleFactor)` | `removed` (with its migration), `deprecated` (with the replacement and the library's own deprecation text) or `ok`, plus the curated notes whose `avoid` names it, each with its source. `ok` means nothing the project imports deprecates or removes it; whether it exists isn't checked (the Dart MCP server's analyzer does that) |
| `what_changed` | optional `since` version; optional `library` (e.g. `package:go_router`) | The curated notes since `since` (`since` narrows only the notes), and per library the number of deprecated, removed, changed and moved APIs in `delta.json`; with `library`, that library's entries in full. `check_api` answers for one name |
| `toolchain` | – | Valid native version set for this SDK, the project's current values from `native.json`, and mismatches (below) |
| `package_check` | package name [+ version] | Exists? discontinued? latest version, last publish, publisher (verified?), Flutter Favorite, SwiftPM support, built-in-Kotlin readiness, advisories, **verdict** (`ok` / `warn` / `block`) + reasons |
| `decisions` / `record_decision` | topic / record | Read or write layer 3 |
| `memory_read` / `memory_write` | – / `{kind, text}` | Read or write layer 4 |
| `verify` | scope (`fast`, `full`, or file list) | Findings (§9.3) |

**`where_is` ranking** is deterministic, with no embeddings:

- the query is split into lowercase words and matched against symbol names (split at camelCase and snake_case), route paths and screen names, feature names and file paths;
- each word scores its best match on a candidate: exact symbol word 5, route path or screen 4, feature name 3, file path 2, fuzzy (edit distance ≤ 2, and both words have at least 4 letters) 1. A candidate's score is the sum over the words; ties are broken by name, then file;
- it returns 10 results: the best-scoring feature, route and file that match, when there are any, then the highest-scoring candidates that remain, listed by score. A word found in many symbol names therefore never hides the feature, route and file it also names;
- each result has the reason for each match and, where the map has them, its file:line, layer, feature and doc-comment summary: a symbol has all of them, a route its file:line and feature, a file its layer and feature, and a feature its folder.

This is enough for a well-structured project; semantic search can be added later if the benchmark shows a need.

**`toolchain` mismatches** use only thresholds Flutter itself applies (§12):

- a value below the version at which Flutter's Gradle plugin fails the build is an error, and below the one at which it warns, a warning;
- a value above the newest version this Flutter knows is a warning;
- a compileSdk below Flutter's minimum, or an iOS deployment target below the SDK template's, is a warning;
- a value `native.json` records as `unknown` is reported as not comparable, with its reason;
- store minimums are shown as the curated notes give them.

The Dart MCP server (`dart mcp-server`) runs **next to** ours. It provides the analyzer, symbols, runtime inspection, hot reload, pub.dev search and package source reading (`read_package_uris`). We don't duplicate those.

---

## 9. Verifier

### 9.1 Fast checks (after every change, changed files only, target < 5 s)

Fast checks **only report; they never modify files** (§5.4).

- `dart analyze` on changed files and their dependents: fail on errors and on `deprecated_member_use*`
- `dart fix --dry-run`: findings for pending `fix_data` migrations, each with the fix it would apply
- `dart format --output=none --set-exit-if-changed` on changed files: a warning, applied later at Stop
- `appstein_lints` rules (§9.6), which run inside the analyzer
- if dependencies changed: the package gate (§9.4) and package skills refresh (§6.6)
- incremental map refresh plus the staleness check

**Fast checks use warm analysis (measured in slice 1a).**
- **The measurement:** a cold single-file `dart analyze` with the plugin took 9–16 s, on CI Linux and Windows and on a developer's Windows machine. Even without the plugin it took 4–8 s, so analysis-server start-up alone misses the target.
- **The design:** fast checks run warm analysis inside the long-running `appstein mcp` process, which the hook contacts over a local socket.
- **When that process isn't running:** the hook falls back to cold analysis, which took 9–16 s for one file in the measured runs, so it misses the 5 s target. The first run after the plugin changes also builds the plugin and may exceed the `fast_timeout_seconds` cap (20 s). Slice 1d measures this and decides what the hook does then.
- **Still to prove:** that warm analysis meets 5 s. Slice 1d measures it.

The measurements are recorded in the 1a plan.

### 9.2 Full checks (at "done", slower)

**Code checks**
- first apply `dart fix --apply` and `dart format` (safe at Stop), then all fast checks on the whole project
- `flutter test`, including accessibility guideline tests (`meetsGuideline`: `androidTapTargetGuideline`, `iOSTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline`)
- `verify.test_required` (warning): every feature folder has at least one test file
- decisions ↔ code consistency (§6.7)
- `docs.stale` (warning): the human docs match the current knowledge and haven't been hand-edited (§6.9). Skipped when `docs.enabled` is `false`

**Android (platform pack)**
- **Toolchain:** the Gradle wrapper, AGP, KGP (when used), JDK and NDK fall inside `toolchain.json`. A version newer than Flutter's "max known" (e.g. AGP 9.4 today) is an error.
- **Built-in Kotlin:** no plugin applies the Kotlin Gradle Plugin when AGP 9 built-in Kotlin is enabled. The plugin graph is read from the resolved plugins in the pub cache.
- **Built-in Kotlin decision:** `android.builtInKotlin` stays `false` (with `android.newDsl=false` where the notes require it) unless **every** plugin has migrated **and** the curated notes mark the Flutter + AGP combination safe (e.g. not AGP 9.3.2+ while #192167 is open). A mismatch in either direction is an error with the reason.
- **Required values:**
  - `namespace` is set.
  - SDK levels use Flutter's variables (`flutter.compileSdkVersion`, `flutter.targetSdkVersion`, `flutter.minSdkVersion`), which the check resolves against the installed SDK. A hard-coded integer is a warning, and an error if it resolves below the requirement.
  - The resolved `compileSdk`/`targetSdk` is ≥ 36 (the Play requirement since 2026-08-31, stored in curated notes so it can change).
  - The resolved `minSdk` is ≥ the highest minimum any plugin requires.
- **16 KB page size** (required for apps targeting Android 15+ since 2025-11-01):
  - the NDK version is at least the one recorded in the notes (r28+);
  - plugins that bundle native libraries (`.so`, CMake) are listed as a warning to verify;
  - when a debug APK is built, `zipalign -c -P 16` checks the alignment (an error if it fails, skipped with an info finding if build-tools are missing).
- **Syntax:** `.kts` files contain no Groovy syntax (e.g. `minSdkVersion 21` without `=`).
- **Cheap gates first:** `flutter analyze --suggestions` (Flutter's own Java/Gradle/AGP compatibility check) and `flutter build apk --config-only` run before the real build, so config errors surface in seconds.
- **Secrets:** no signing or store secrets are tracked by git: `*.jks`, `*.keystore`, `key.properties`, `*.p8`, `*.p12`, `*.mobileprovision`, `ExportOptions.plist`, `.env*` files with keys, and `--split-debug-info` output folders.
- **Release readiness (static):**
  - the application ID is set and is not the template default (`com.example.*`);
  - the app label is not the template default;
  - the launcher icon is not the default Flutter icon (warning);
  - `version:` is set in `pubspec.yaml`;
  - a release signing config exists or is clearly marked TODO (warning).
- **Build:** when `build_on_full` is on, a real `flutter build apk --debug` succeeds.

**iOS (platform pack)**
- **Deployment target:** ≥ the SDK minimum (15 for Flutter 3.47, from curated notes) and consistent across `project.pbxproj`, `Podfile` (if present) and `Package.swift` (if present).
- **SwiftPM:** enabled. Plugins without SwiftPM support are listed with the CocoaPods trunk read-only date (2026-12-02); this is a warning unless the project has CocoaPods removed, in which case it's an error.
- **UIScene:** a `UIApplicationSceneManifest` is present in `Info.plist`, and an AppDelegate customized beyond the template uses the implicit-engine pattern (`FlutterImplicitEngineDelegate`).
- **Privacy:** `PrivacyInfo.xcprivacy` is present.
- **Usage descriptions:** `Info.plist` has one for every permission required by the plugins in use. The permission ↔ plugin mapping lives in the iOS pack, derived from each plugin's documented requirements, and is extended over time.
- **Release readiness (static):** the bundle ID is set and not the template default, the display name is not the default, the app icon set is not the default (warning), and build name/number come from `pubspec.yaml`.
- **Platform limits:** these checks are static on Windows and Linux. On macOS, `build_on_full` also runs `flutter build ios --debug --no-codesign`.

### 9.3 Finding format (defined in `appstein_protocol`)

```json
{
  "id": "android.kgp_applied_by_plugin",
  "severity": "error",
  "file": "android/app/build.gradle.kts",
  "line": 3,
  "message": "Plugin 'foo_plugin 1.2.0' applies the Kotlin Gradle Plugin; AGP 9 built-in Kotlin will fail to build.",
  "fixHint": "Upgrade foo_plugin to >= 1.3.0 (migrated) or replace it; see package_check.",
  "knowledgeRef": ".appstein/platform/toolchain.json#kotlin",
  "pack": "android",
  "docs": "https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers"
}
```

- **Severities:** `error` blocks "done"; `warning` is reported only; `info` is advisory.
- **Check IDs** follow `<pack or area>.<check>` and are stable once released.
- **Text output** groups findings by file, errors first, and ends with a one-line summary.

### 9.4 Package gate

The gate runs on any change to dependencies and through the `package_check` MCP tool. It uses pub.dev's public API and advisory data.

| Condition | Result |
|---|---|
| Package doesn't exist on pub.dev (likely hallucinated) | **error** |
| Package is marked discontinued | **error** (the replacement is shown if pub.dev lists one) |
| Resolved version has a known security advisory | **error**. It becomes a warning only if the advisory is in `pubspec.yaml`'s `ignored_advisories` **and** a matching human-approved suppression with a reason exists in `appstein.yaml`. An `ignored_advisories` entry without that suppression is itself an error, so an agent can't silence an advisory. OSV-Scanner can optionally run as an extra gate if installed |
| Listed in `packages.deny` | **error** |
| Plugin lacks SwiftPM support | **error** if CocoaPods has been removed from the project, otherwise **warning** |
| Plugin applies the Kotlin Gradle Plugin and the project uses AGP 9 built-in Kotlin | **error** |
| Last publish older than `stale_after_months` | **warning** (unless in `packages.allow`) |
| Verified publisher / Flutter Favorite / publisher is `dart.dev` or `flutter.dev` | **info**, shown as positive signals |

**How native readiness is detected:**

- **Before resolution** (a package being considered, via `package_check`): pub.dev metadata. pub.dev scoring rewards SwiftPM support, so its score tags show it. For built-in Kotlin, the latest version's published archive is inspected.
- **After resolution** (packages in `pubspec.lock`): the exact resolved sources in the pub cache are inspected. SwiftPM support means a `Package.swift` in the plugin's `ios/` or `darwin/` folder. The Kotlin Gradle Plugin shows up in the plugin's `android/build.gradle(.kts)`. Native libraries show up as `.so` files, `jniLibs/` or CMake files.

Results are cached in `.appstein/state.json` for 24 hours. **Offline:** existence and advisory checks can't run, so the gate reports a warning (`package.unverified_offline`) and never blocks on its own network failure. Pub-cache inspection works offline.

### 9.5 Exit codes

| Code | Meaning |
|---|---|
| `0` | No errors |
| `1` | Errors found (CLI and CI use) |
| `2` | Errors found in `--hook claude` mode. Claude Code treats exit code 2 from PostToolUse and Stop hooks as "block and feed stderr back to the model". `--hook codex` maps to whatever blocking mechanism Codex supports, which is verified in slice 1e |
| `3` | Appstein itself failed (bad environment, crash, invalid config). In hook mode this **never blocks the agent silently**: it prints a clear message to run `appstein doctor` and lets the agent continue. `doctor` is the exception: diagnosing a bad environment or an invalid `appstein.yaml` is its job, so it reports them as failed checks (`1`) and exits `3` only when it can't run at all (bad usage or a crash) |

### 9.6 Lint rules in M1 (`appstein_lints`, one test file per rule)

| Rule | Enforces |
|---|---|
| `layer_imports` | **Tag-based** constraints declared by the stack pack (following Twenty's `enforce-module-boundaries`). A layer may import the tags it `allow`s. From the tags listed under its `interfaces`, it may import only files whose classes are all abstract: a repository's interface, not its implementation. For `official_mvvm`, matching Flutter's architecture guide and its compass_app sample: `ui` → `domain`, `routing`, `config` and `utils`, plus the interfaces of `data.repository` and `data.service`; `domain` → `utils`, plus the interfaces of `data.repository` (use cases call repositories); `data.*` → anything but `ui`; `routing`, `config`, `utils` and tests are unrestricted |
| `no_hardcoded_colors` | No `Color(0x…)` / `Colors.*` literals in the `ui` layer; use `ColorScheme` or tokens |
| `use_spacing_tokens` | No non-zero numeric `EdgeInsets`/`SizedBox`/`Gap` literals in `ui`; use the tokens from the `ThemeExtension` |
| `no_platform_branching_in_layout` | No `Platform.isX` / `defaultTargetPlatform` checks inside `build` methods (Flutter's adaptive-design guidance) |
| `no_orientation_lock` | No `SystemChrome.setPreferredOrientations` locks (adaptive-design guidance; Android 17 also ignores orientation restrictions on large screens) |
| `document_public_classes` | A `///` doc comment on every public class in the layers the human docs render (for `official_mvvm`: view models, repositories, services, domain models and routed screens). Severity **warning**. Its first sentence becomes the class summary in `symbols.json` and in `docs/app/` (§6.9). Written for humans, so it says what the class is for, not how it is implemented |

**Where the lints get their rules:**

- Layer rules come from the stack pack but are written into the project's `analysis_options.yaml` as a **top-level `appstein_lints:` section** (next to `plugins:`), by `create`, `integrate` and `sync` (which rewrites the section if the pack changes). They're committed, so the lints work in any IDE even before the first sync.
  - **Why top-level:** the analyzer rejects custom keys inside a plugin's own `plugins:` entry (it accepts only `path`, `version`, `git`, `hosted` and `diagnostics`, and warns `unsupported_option` otherwise), and plugins get no configuration API. A top-level section raises no warning, and a rule reads it from the nearest `analysis_options.yaml` above the file it analyzes. Verified on Flutter 3.47.5 / Dart 3.13.4 with `analysis_server_plugin` 0.3.23 (2026-09-29).
  - Plugin rules are off by default, so `create`/`integrate` also list every rule under `plugins: appstein_lints: diagnostics:`.
- The `appstein_lints` version is pinned by `integrate` to match the installed `appstein` CLI, and `doctor` reports a mismatch.
- The same rules, with a repo-specific config, enforce **Appstein's own** package boundaries.

### 9.7 Suppressions

Professionals need an escape hatch that stays visible:

- **Dart code:** `// appstein:ignore <check-id> — <reason>` on the line, or `// appstein:ignore-file <check-id> — <reason>`. Lint rules also honour the analyzer's standard `// ignore:` comments.
- **Native and other files:** a `suppressions:` list in `appstein.yaml` with `id`, `path` and `reason`.
- **A reason is mandatory.** A suppression without a reason is itself an error.
- `verify` prints a count of active suppressions, so they never disappear silently.

---

## 10. Packs

```dart
abstract interface class Pack {
  String get id;                          // "official_mvvm", "android", "ios"
  PackKind get kind;                      // stack | platform
  String get version;                     // pack version, for migrations
  List<Extractor> get extractors;         // contribute to layer 2 (and platform facts)
  NativeExtractor? get nativeExtractor;   // platform packs: map/native.json (§6.5)
  List<Check> get checks;                 // contribute to verify
  LayerRules? get layerRules;             // tag rules for layer_imports (stack packs)
  List<SkillSource> get skills;           // pack-specific skills/references
  ProjectTemplate? get template;          // used by `create`
  List<Migration> get migrations;         // used by `upgrade`
  List<DocPage> get docPages;             // human doc pages + concept text (§6.9)
}
```

- **M1 packs:** `official_mvvm` (stack), `android` and `ios` (platform).
- **The interface grows with the slices.** Each member is added in the slice that first uses it. Slice 1b.3 adds `id`, `kind`, `version`, `extractors` and `layerRules`. Slice 1b.4 adds `nativeExtractor`.
- **Later packs:** `riverpod` and `bloc` (M3, together with support for existing projects), then `web`, `windows`, `macos` and `linux` (M4+). **The final goal is every platform Flutter supports.**
- **Community packs** defined in code (inspired by Twenty's `defineObject`) and a pack scaffold: M3+.
- **A pack must never read another pack's data directly.** Shared facts (e.g. the resolved plugin graph) are provided by the engine through the protocol.

---

## 11. Agent integration (M1)

`appstein integrate` writes **project-level** configuration only. It never writes user-global config and never touches credentials. Every file it writes contains an "Appstein-managed" marker, so `integrate --remove` can undo it cleanly and re-running it updates without duplicating.

### 11.1 Claude Code

- **Official plugin:** enables Google's `flutter/agent-plugins` (the `dart-flutter` plugin) at a **pinned version** recorded in `appstein.yaml` (managed section).
  - **To verify in 1e:** whether project-level plugin enabling works through `.claude/settings.json` (`extraKnownMarketplaces` / `enabledPlugins`). If it doesn't, `integrate` prints the exact one-time user commands (`claude plugin marketplace add flutter/agent-plugins`, `claude plugin install dart-flutter@dart-flutter`) instead of changing user config.
  - Known-broken official skills are overridden by a same-named project skill. Today these are `flutter-setup-localization` (broken on 3.47.2) and `flutter-add-integration-test` (calls the disabled `launch_app` tool; our version uses the CLI).
- **Exactly one Dart MCP server.** The official plugin already registers `dart mcp-server`, with default flags. Appstein uses that server as-is and does **not** add a second copy.
  - The tools it disables by default (`dart_fix`, `dart_format`, `run_tests`, launch tools) aren't needed: fix, format and tests are run by our verifier and hooks, and the Dart team itself says agents do better using the CLI for app lifecycle.
  - If the official plugin can't be enabled (e.g. the user declines), `integrate` registers `dart mcp-server` in `.mcp.json` itself.
  - **To verify in 1e:** that no duplicate is registered in either case.
- **`.mcp.json`:** `appstein mcp` (plus `dart mcp-server` only in the fallback case above).
- **`.claude/settings.json` hooks:**
  - `SessionStart` → `appstein sync`.
  - `PostToolUse` on `Edit|Write|MultiEdit|Bash` → the fast path (§5.4). For Bash, changed files are detected by content hash, and a Bash command that changed nothing costs one hash scan.
  - `Stop` → apply fix and format, render the human docs (§6.9), then full verify, with the loop guard (§5.4).
  - Hook commands call the `appstein` binary directly (no shell scripts), so they work on Windows.
- **`.claude/skills/`:** Appstein skills (§11.3).
- **`CLAUDE.md`:** created or updated with an Appstein-managed block containing:
  - a one-line pointer to `.appstein/INDEX.md`;
  - the key workflow rules ("ask the Appstein MCP before searching; run verify before claiming done; never change native toolchain versions yourself; never edit generated pages in `docs/app/`, write `///` doc comments instead");
  - the official plugin's `flutter-hot-reload` rule text, because Claude Code doesn't auto-load plugin rules.

### 11.2 Codex

- **`AGENTS.md`:** the same Appstein-managed block, plus "call the `overview` MCP tool first" (in place of the SessionStart hook) and the official plugin's rule text.
- **Skills:** installed into `.agents/skills/`, the location `package:skills` and the official docs use for Codex.
- **Official plugin:** `codex plugin marketplace add flutter/agent-plugins` / `codex plugin add dart-flutter@dart-flutter`, printed for the user if it can't be configured per project. The one-Dart-MCP-server rule from §11.1 applies.
- **MCP config:** `appstein mcp` (and `dart mcp-server` in the fallback case) in Codex's MCP config. The exact file (project-level vs `~/.codex/config.toml`) is verified in 1e. If only user-level config exists, `integrate` prints the lines to add instead of editing user config.
- **Hooks:** Codex hook support is verified in 1e. If hooks are unavailable, `AGENTS.md` instructs Codex to run `appstein docs` and call the `verify` MCP tool before finishing, and the CI template (§13.1) enforces `appstein verify --full` on every push.

### 11.3 Appstein skills (in `skills/`, tested in CI)

Skills are organized by **lifecycle** (following Twenty's `twenty-agent-skills`) and kept short. They **point to generated knowledge instead of copying it**.

| Skill | Covers |
|---|---|
| `appstein-develop` | The core workflow: read INDEX → query MCP → follow the pack's structure → verify; how to read findings; how to record decisions and memory; how to write doc comments that serve human readers (§6.9) |
| `appstein-theming` | Design tokens with `ThemeExtension`, `ColorScheme.fromSeed`, typography scale, spacing, dark mode, text scaling. Material 3 Expressive and iOS 26 Liquid Glass have **no official Flutter implementation**; community packages are an opt-in dependency risk that must pass `package_check` |
| `appstein-native-config` | How to change Gradle/iOS config safely within `toolchain()`; never "upgrade to latest"; AGP 9 built-in Kotlin, SwiftPM, UIScene, privacy manifest basics |
| `appstein-dependencies` | The dependency policy (§14), `package_check`, and what to do with warn/block verdicts |
| `appstein-accessibility` | Semantics labels, tap targets (48×48 Android / 44×44 iOS), text contrast (4.5:1 normal, 3:1 large text), text scaling to 2.0, focus order, writing `meetsGuideline` tests, and the gaps automated tests don't cover (non-text contrast for icons and focus rings, screen-reader flow). It covers the same ground as the Antigravity-only official a11y agent, for any agent. **It is written independently from public Flutter docs and WCAG**, not copied from the extracted official agent prompt, which isn't published under a license |
| `appstein-ui-states` | Every screen handles loading, empty, error and success states, with the Command pattern from Flutter's architecture guide |
| `appstein-ship` | Pre-release configuration: app/bundle IDs (human-confirmed), signing setup (human-confirmed, secrets never in git), launcher icons, splash screen (Android 12+ rules), versioning, flavors/environments (including the conflict between flavors and the default `abiFilters` since 3.35), obfuscation with `--split-debug-info` (output kept out of git), R8/ProGuard keep rules |
| `appstein-use-mcp` | The MCP tools and when to use each instead of searching (following Twenty's `use-twenty-mcp`) |

**CI for skills:**

- **Snippet analysis:** every Dart code block in every skill is extracted and run through `dart analyze` against the **current stable SDK** and the **minimum supported SDK** (§19.3). Any deprecated or invalid snippet fails CI. This keeps our skills from going stale the way the official ones did.
- **Link check:** every link in a skill must resolve.
- **Size budget:** each skill is at most 2,000 tokens (estimated as characters ÷ 4).
- **Smoke test:** a documented `SKILLS-SMOKE-TEST.md` procedure runs each skill with a real agent on the fixture app before each release (following Twenty's `SMOKE-TEST.md`).

---

## 12. Native toolchain matrix (`toolchain.json`)

- **Android:** parsed from two files in the installed SDK:
  - `flutter_tools/lib/src/android/gradle_utils.dart`: template versions (Gradle, AGP, KGP, NDK, compile/target/min SDK), the minimum build-tools and Java versions, "max known" versions, and the Java↔Gradle and AGP↔Java compatibility lists;
  - `flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt`: the versions below which Flutter's Gradle plugin warns or fails the build (Gradle, AGP, KGP, Java, minSdk).

  If either file's structure changes and parsing fails, Appstein falls back to the matrix in the newest curated notes file at or below the installed version, and reports `toolchain.fallback` (info).
- **Play target API** and other store-imposed minimums come from the curated notes (they change on Google's schedule, not Flutter's).
- **iOS/macOS:** the minimum deployment target is read first from the installed SDK's own iOS and macOS app templates (`IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET` in their `project.pbxproj`). The curated notes are the fallback if parsing fails. The required Xcode version (Xcode 26 for App Store uploads since 2026-04-28) comes from the curated notes.
- **Open issues are recorded as notes.** For example, #192167 (built-in Kotlin fails Flutter's Kotlin version check on AGP 9.3.2+) becomes a note that steers `create` and `toolchain()` to a known-good combination until it's fixed.

---

## 13. `create` and `upgrade`

### 13.1 `appstein create <name>`

1. **Preflight.** Run the `doctor` checks and stop with clear fixes if something required is missing. Ask for the **organization and application/bundle ID**, and confirm that these are permanent after the first store upload. Ask for the display name.
2. **Base project.** `flutter create --org <org> --platforms android,ios --project-name <name> <dir>`.
3. **Apply the `official_mvvm` template.**
   - **Structure:** `lib/ui/<feature>/{view_models,widgets}`, `lib/ui/core/` (shared widgets and themes), `lib/data/{repositories,services}`, `lib/domain/models`, `lib/routing/`, `lib/config/dependencies.dart`, `lib/utils/` (Result and Command, from Flutter's architecture guide).
   - **Dependencies:** `go_router` and `provider` at versions that pass `package_check`.
   - **Theme:** light and dark themes from `ColorScheme.fromSeed`, plus an `AppTokens` `ThemeExtension` for spacing, radii and extra colors.
   - **Localization:** l10n scaffolding done correctly for the installed SDK (not via the broken official skill).
   - **Version-specific choices** come from the delta. For example, if the SDK is ≥ 3.47 the template uses `material_ui` instead of `package:flutter/material.dart`, **but only if** every template dependency is compatible (its bridge can't fix type mismatches when a dependency exposes in-framework Material types). Otherwise it keeps the in-framework import and records a note for `upgrade`. The actual compatibility of `go_router` and `provider` is verified in 1e.
4. **Native config.** Set Android and iOS to `toolchain.json` values:
   - AGP, Gradle, KGP and JDK;
   - SDK levels, keeping Flutter's `flutter.*` variables, not hard-coded integers;
   - namespace;
   - `builtInKotlin` / `newDsl` per the rule in §9.2;
   - deployment targets;
   - SwiftPM on, UIScene manifest, privacy manifest.
5. **Sample feature.** One feature (screen + view model + repository interface + implementation + fake + unit, widget and accessibility guideline tests), with `///` doc comments written for human readers, so agents have a correct example to copy.
6. **Project files.**
   - `appstein.yaml`;
   - `analysis_options.yaml` with `appstein_lints` enabled;
   - `.gitignore` entries;
   - a project README section ("how this project is set up, how to run `appstein sync`");
   - a CI template: `.github/workflows/appstein.yml` running `appstein verify --full` on Linux (Android) and macOS (iOS).
7. **Finish.**
   - `appstein sync` → `appstein docs` (the first human docs in `docs/app/`, §6.9) → `appstein integrate` (agents from preflight) → `appstein verify --full`, which **must pass**, otherwise `create` reports the failure.
   - Initialize git and propose the first commit. Nothing is committed without confirmation.

**If any step fails,** `create` stops, prints what was done and what failed, and leaves the directory for inspection. It never deletes a directory it didn't create.

### 13.2 `appstein upgrade`

Migrations are versioned, with **one folder per Flutter minor version** and one per `.appstein/` format version (following Twenty's `upgrade-version-command/2-8, 2-9` layout).

- **Structure of a migration:** `id`, `appliesTo` (version range), `check` (is it needed?), `apply`, and a human-readable description.
- **Running:** `upgrade` runs every applicable migration in version order. `--dry-run` lists what would change as a diff preview, without writing.
- **Flutter's migrators first:** migrations invoke Flutter's own migrators (`dart fix`, `flutter` tool migrations) before rewriting any file themselves.
- **Undo:** there are no "down" migrations for user projects. Git is the undo mechanism, and `upgrade` refuses to run on a dirty working tree unless `--allow-dirty` is passed.
- **Example:** `3.47/` moves the project to `material_ui` / `cupertino_ui` and adds the dependencies to `pubspec.yaml`, which `dart fix --code=migrate_design_widgets` may skip.

---

## 14. Dependency policy (taught by skill, enforced by the package gate)

| Situation | Choice |
|---|---|
| Small helper (formatting, validation, simple state, HTTP wrapper) | **Write it in pure Dart**. No native config impact |
| Complex platform feature (camera, permissions, notifications, payments, maps, auth) | **Use a well-maintained package** that passes `package_check` |
| Small native feature with no good package | **Write it with Pigeon + platform channels**. Not jnigen or swiftgen (unstable and error-prone for agents) |
| Any new dependency | Must pass the package gate (exists, not discontinued, no advisories, maintained, SwiftPM and built-in-Kotlin ready) |

Even first-party packages can be discontinued (`flutter_markdown`, 2025), so the gate treats every publisher the same way and shows publisher signals only as information.

---

## 15. Non-functional requirements

| Area | Requirement |
|---|---|
| **Performance** | Fast verify < 5 s on the fixture app (hard cap from config); incremental sync (`sync --detect` after one edit) of a 200-file app < 2 s; MCP tool responses < 1 s from fresh knowledge; full sync of a 200-file app < 30 s; `appstein docs` from fresh knowledge < 2 s. Measured in CI on every change. The sync targets leave out a package skills run (§6.6): it happens only when dependencies change, and its time depends on the network |
| **Startup** | Hooks invoke a compiled executable (AOT), not `dart run`, so start-up stays under 200 ms |
| **Platforms** | Appstein runs on Windows, macOS and Linux (x64 and arm64 where Dart supports AOT). Paths with spaces and non-ASCII characters are supported |
| **Concurrency** | Writes to `.appstein/` take an operating-system lock on `.appstein/.lock`, waiting up to a timeout, so two hooks or two agents never corrupt knowledge. The operating system releases the lock if a writer crashes, so a stale lock never blocks. Each file is written beside its target and then renamed over it, so readers never block and never see a half-written file |
| **Offline** | Everything except package existence and advisory checks works offline. Network failures degrade to warnings and never block |
| **Privacy** | No telemetry, no analytics, no code leaves the machine. Network calls: pub.dev API and advisory data; optional integrations only if enabled |
| **Robustness** | A crash or bad environment gives exit code 3 with a helpful message and never masquerades as findings. The exception is `doctor`, whose findings are exactly those problems (§9.5) |
| **Determinism** | The same inputs give byte-identical generated knowledge and human docs (sorted keys, stable ordering, no timestamps in committed docs), so golden tests and caching work and git diffs show only real changes |

---

## 16. Optional integrations (off by default)

| Integration | What it adds | Why optional |
|---|---|---|
| **graphify export** (`integrations.graphify_export`) | `sync` also writes Appstein's Flutter-aware facts (features, routes, layers, native config) in a form graphify can merge, so users who run graphify get code + docs + Flutter semantics in one graph | graphify needs Python and `uv`; Flutter developers shouldn't be forced to install it. Planned for after M1 core slices; format verified against graphify's `graph.json` at that time |
| **Google Developer Knowledge MCP** (`integrations.developer_knowledge_mcp`) | Live search of docs.flutter.dev and dart.dev for agents | Needs a Google Cloud project and API key; quotas undocumented |
| **Marionette MCP / mcp_flutter** | Agents drive and screenshot the running app | Planned for M2 visual verification (§21) |

**Building blocks to evaluate for composition after M1** (we reuse good work instead of rebuilding it):

- Very Good Ventures' Claude Code plugin (14 skills, incl. a WCAG 2.2 skill and its "Green Gate" loop);
- the Very Good CLI MCP server;
- Firebase's official agent skills, for apps that use Firebase.

Each needs a license and fit check before we depend on it.

---

## 17. Benchmark (proof of value)

The benchmark lives in `benchmark/`.

- **Fixture apps:**
  - **fresh**: created by `appstein create`;
  - **legacy**: a realistic app full of pre-3.27 APIs, an imperative Gradle setup and CocoaPods;
  - **control**: the same apps without Appstein installed.
- **10–20 tasks**, for example:
  - add a feature with a route;
  - add a screen with a form and validation;
  - add a permission-requiring feature (camera);
  - add a dependency (including one that tempts a hallucinated package name);
  - fix a layout overflow;
  - add dark-mode support;
  - make a screen accessible;
  - bump a plugin that needs native changes.
- **Runs:**
  - Each task is executed by Claude Code (`claude -p --output-format stream-json`) **with** and **without** Appstein, with at least 3 runs per task per arm to account for model variance.
  - The owner runs it on their own subscription with the unmodified binary, which the vendor terms permit.
  - Runs never use `--bare`, which ignores subscription login and is planned to become the default for `-p`. The runner checks the stream's init event to confirm the subscription login is active before counting a run.
  - Permission flags are pinned (`--permission-mode` and `--allowedTools`), so both arms run with identical permissions.
- **Metrics:**
  - total tokens and cost (from stream-json usage);
  - turns and tool calls (especially search/read calls);
  - deprecated-API findings in the final code;
  - `verify --full` pass rate;
  - Android build success;
  - wall time.
- **Output:** a results table in `benchmark/results/<date>.md` and a README section. There are **no invented targets**: the first run sets the baseline, and the M1 exit criteria are relative to it (§18).
- **Contribution:** no public Flutter version-drift benchmark exists (FlutterBench is unreleased). Publishing ours is part of Appstein's credibility.

---

## 18. Milestones

### M1: Knowledge + verification foundation (this spec)

| Slice | Delivers | Exit criteria |
|---|---|---|
| **1a** | Workspace with 4 packages; `appstein` CLI skeleton; `--version`; `config/` + `appstein.yaml`; `sdk/` detection (incl. FVM, language version); `doctor`; CI for our repo; boundary lint on our own repo; AOT build; developer guide skeleton + `public_member_api_docs` + `dart doc` in CI (§19.6) | `doctor` correct on Windows, macOS and Linux CI; CI green; minimum supported Flutter version confirmed; guide "start here" page lets someone build and run the CLI from source |
| **1b** | Knowledge layers 1–2 (sdk, delta + curated notes for 3.44–3.47, toolchain, map via `official_mvvm` + platform extractors, incl. doc-comment summaries in `symbols.json`), INDEX.md, `sync` (full + incremental), staleness metadata, lock file, package skills refresh | Golden tests pass on fixtures; INDEX ≤ 1,500 tokens; performance targets (§15) met for sync |
| **1c** | MCP server with the §8 tools except `verify` and `package_check`, which 1d builds with their engines; layers 3–4 read/write with formats from §6.7–6.8; human docs renderer + `appstein docs` + pack doc pages (§6.9) | Each tool tested; works from Claude Code on a fixture; golden tests for every doc page; re-rendering unchanged knowledge changes no bytes |
| **1d** | Verifier: fast + full checks, Android + iOS checks incl. static release readiness, package gate incl. advisories and offline behavior, `appstein_lints` M1 rules (incl. `document_public_classes`), `docs.stale`, suppressions, exit codes, the `verify` and `package_check` MCP tools | Every check has a passing and a failing fixture; fast verify < 5 s; both tools tested |
| **1e** | `create` (incl. CI template and first human docs), `integrate` (Claude Code, Codex, `--remove`, one-Dart-MCP rule, hooks incl. SessionStart, Bash detection, the loop guard and docs rendering at Stop), verification of every "to verify in 1e" item | `create`→`verify --full` green on Linux + macOS CI; integration works end-to-end in both agents; every "to verify" item resolved and the spec updated |
| **1f** | `upgrade` framework + 3.47 migration; all lifecycle skills + skills CI + smoke-test procedure; benchmark runner and first published run | Skills CI green on current stable and minimum SDK; the 3.47 migration tested on the legacy fixture; benchmark published |

**M1 is done when:**

- all slice exit criteria pass;
- with-Appstein benchmark runs produce **zero** deprecated-API findings in final code and a **higher** `verify` pass rate than the control;
- token usage is reported honestly, whether it went up or down;
- the owner has used Appstein on at least one real project and signed off;
- the owner can understand the fixture app from its `docs/app/` alone, without asking an agent.

### Later milestones (direction only; each gets its own spec)

- **M2: Single-agent pipeline harness.**
  - The engine drives the official CLIs through their structured interfaces (Claude `-p --output-format stream-json`, Codex `app-server`, ACP for others) in a **plan → implement → review → verify** pipeline with hard gates.
  - It includes a trust prompt before launching agents in a repo, explicit auth flags, and the rule that the user always logs in through the vendor's own flow.
  - It adds **visual verification** (§21).
  - Beginners get a guided mode here.
- **M3: Existing projects + more stacks + community.**
  - `appstein adopt` maps an existing project, reports gaps and proposes a migration path.
  - Riverpod and Bloc packs, community packs and a pack scaffold.
  - Reading Groovy Gradle build files, if needed (projects created before Flutter 3.29; see §6.5).
- **M4: Flutter desktop app + multiple agents + every platform.**
  - **Client:** the app is a client of the engine over authenticated localhost JSON-RPC/WebSocket.
  - **Rendering:** it renders structured agent events as native widgets (the idea behind Brainless), with a utilitarian design, not a themed "office". It never copies Claude Code's look or name (Anthropic branding rules). A raw terminal is only a fallback.
  - **Parallel agents** run in git worktrees only for truly independent units.
  - **Platforms:** web, Windows, macOS and Linux platform packs.
  - **Then** a web UI on the same engine and protocol.

---

## 19. Development workflow for the Appstein repo

### 19.1 Tooling

- **graphify from the first commit.** The graph covers code, this spec, the research report and docs. Git hooks rebuild its code structure on each commit, checkout, merge and rebase. What the docs mean (the semantic layer) needs an LLM, so `/graphify . --update` refreshes it, and a hook warns whenever a doc's current content isn't in the graph (§19.6). Agent sessions start from the graph instead of rediscovering the repo, and update it first when it is behind.
- **`CLAUDE.md` / `AGENTS.md`** are short: commands, architecture at a glance, rules and "critical gotchas" (Twenty's style). No duplicated architecture prose that can drift; they point to this spec, to graphify and to the developer guide (§19.6).
- **Dependency hygiene** in our own repo: `dependency_validator` in CI (the Dart equivalent of Twenty's `knip`).

### 19.2 Environment

- **Required:** Dart SDK and Flutter SDK (stable, plus the minimum supported version via FVM), JDK 17, Android SDK, git, and `uv` + graphify for dev tooling.
- **macOS only:** Xcode and CocoaPods for iOS work; on Windows, iOS work relies on CI.

### 19.3 CI (GitHub Actions)

| Job | Runs |
|---|---|
| `analyze` | `dart format --set-exit-if-changed`, `dart analyze` (incl. our boundary lints and `public_member_api_docs`), `dependency_validator` |
| `test` | Unit + golden tests on Linux, Windows and macOS |
| `skills` | Snippet analysis against current stable and minimum supported SDK; link check; size budget |
| `docs` | `dart doc` for every package, failing on warnings; developer guide checks (§19.6): snippet analysis, link check, every file path it mentions exists, every source file covered by a page, no stale pages, generated sections up to date, and the progress record consistent with the plans and §18 |
| `integration-android` | `appstein create` → `verify --full` on Linux (real Android debug build) |
| `integration-ios` | `appstein create` → `verify --full` on macOS (real iOS debug build) |
| `integration-windows` | `appstein create` → `verify --full` on Windows (Android build) |
| `release` (tags only) | Build AOT executables per platform, publish packages to pub.dev, attach binaries to the GitHub Release |

### 19.4 Git and process

- **Git:** agents may run read-only git. Commits happen only with owner approval, and nothing is pushed unless asked. Commits may include the Co-Authored-By trailer.
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs (API doc comments, the guide pages for what the slice built, the slice's entry in `docs/superpowers/progress.yaml` marked done, with its pull request number once the PR is open, `gen_docs` and the guide check (§19.6), then `/graphify . --update` until the graph warning is silent) → owner review → commit. The warning must still be silent when a slice merges, because edits made after the update put the graph behind again.

### 19.5 Distribution and versioning

- **Install:** `dart pub global activate appstein` (pub.dev), or a standalone binary from GitHub Releases. Hooks use the compiled executable, and `doctor` tells the user if only the pub snapshot is available.
- **Versioning:** Appstein follows semver. `appstein_protocol` carries its own version, and `.appstein/` files record the format version so `upgrade` can migrate them.
- **License:** the Apache License 2.0 (`LICENSE` at the repo root). Contributions are accepted under the same license (Apache-2.0 §5), with no CLA. Each package gets its own copy of `LICENSE` when it is first published to pub.dev.

### 19.6 Documentation for humans working on Appstein

graphify and `AGENTS.md` serve agents working on this repo. People need their own way in: the owner (who is learning Dart CLI development), future contributors, and anyone reading the code when no agent is involved. Appstein's own repo gets three layers of human documentation, each with one job:

| Layer | Answers | Where | Kept correct by |
|---|---|---|---|
| **Spec** | What we decided and why | `docs/superpowers/specs/` | Owner review (it is the source of truth) |
| **Developer guide** | How the code works now, and how to change it | `docs/guide/` | CI checks (below) and the per-slice docs step |
| **API reference** | What each public class and function does | `///` doc comments → `dart doc` (pub.dev hosts it for published packages) | `public_member_api_docs` lint + `dart doc` in CI |

**API reference:**

- Every public API in all 4 packages has a `///` doc comment. Dart's built-in `public_member_api_docs` lint enforces it; we reuse it instead of writing our own rule.
- Each package has a `README.md`: what it is for, what it may depend on (the boundary rules, §5.1), its main entry points and how to test it.
- `dart doc` runs in CI and fails on warnings (broken references, unresolved links).

**Developer guide (`docs/guide/`)**, written for someone learning to build a large Dart CLI, so it explains *why* as well as *how*:

| Page | Covers |
|---|---|
| `README.md` | Start here: set up on Windows, macOS or Linux; a tour of the repo; build and run the CLI from source; run the tests |
| `architecture.md` | The overview: how the whole system works now. How one command flows CLI → engine → packs → protocol, and how hooks and the MCP server enter the same engine, with diagrams. It links to the area pages for detail |
| Area pages | One page per area of the system, explaining how it works and why: for example `doctor` and how it finds the SDKs and JDK, config, running processes, the lints, CI. A page is added in the slice that builds its area |
| `how-to/` | One page per common change: add a check, an extractor, a lint rule, an MCP tool, a curated note, a migration, a doc page, a pack |
| `testing.md` | How the tests are built: fakes, temporary folders, integration tests against the real machine and the cross-check with `flutter doctor -v`. Later: fixture apps, golden tests and how to update goldens safely |
| `debugging.md` | Running hooks and the MCP server by hand, Windows path pitfalls, exit code 3 and `doctor` |

**Keeping the guide correct:**

- A guide page is written **in the slice that builds the thing it describes**, never ahead of the code. The per-slice process has a docs step for this (§19.4).
- **Every source file has a page.** Each page starts with a hidden `<!-- covers: … -->` comment listing the paths it explains. Source means `packages/*/lib/`, `packages/*/bin/`, `tool/` and `.github/workflows/`. The guide check fails if any source file is covered by no page.
- **Code changes come with their page.** In CI, the check fails when a change edits a covered file but not the hand-written text of any page covering it (a regenerated section alone doesn't count). If the page is still right, a commit trailer `Docs-Checked: <page> - <reason>` says so and clears it. This is the idea behind `docs.stale` (§6.9), applied to our own repo.
- **Facts the code already knows are generated, not typed.** `tool/gen_docs.dart` writes them between `<!-- generated:<name> -->` markers: the doctor checks, the CLI commands and exit codes, the CI jobs and the package dependency diagram. CI fails if regenerating would change a page.
- **Progress is data, not prose.** `docs/superpowers/progress.yaml` records every milestone and slice: its status (done, next or planned), its plan, its pull request (or, for a slice merged in the old private repo, its merge commit), the date it finished and what it delivered. `gen_docs` renders it into the spec's visual page as a status line at the top and a progress section with the milestone rail and the slice timeline. The guide check fails when:
  - the page doesn't match the file;
  - a plan in `docs/superpowers/plans/` belongs to no slice;
  - a plan with notes from execution belongs to a slice that isn't done;
  - a done slice has no plan, or neither a pull request nor a merge commit;
  - a merge commit isn't in the repo;
  - a §18 slice is missing;
  - more than one slice is next.
- **CI is the gate; local hooks warn early.** `tool/install_hooks.dart` installs the repo's git hooks: graphify's code rebuild (on commit, checkout, merge and rebase), a post-commit warning when a page is stale or a generated section is out of date, and a graph warning after each commit, merge and rebase naming the docs whose current content isn't in the graph (new, changed or deleted). After each checkout, merge and rebase, a background job waits for graphify's rebuild, rebuilds the code structure once more, and puts back, from graphify's cache and without an LLM, any doc a rebuild dropped from the graph although its extraction is cached; the warning reports those as being repaired and names only what needs `/graphify . --update`. CI can't check the graph because it doesn't have one, so the per-slice rule (§19.4) keeps that warning silent before a merge.
- CI (`docs` job, §19.3) analyzes every Dart snippet in the guide, checks every link, and checks that every repo path the guide mentions exists, reusing the skills CI tooling (§11.3).
- The guide never restates the spec. The spec is the *design*, what we decided and why; the guide is the *current system*, how it works. The guide links to the spec instead of repeating it.

**Not dogfooded:** Appstein's `docs/app/` renderer (§6.9) targets Flutter apps, and this repo is a Dart CLI workspace, so it doesn't run here.

---

## 20. Migration from the old repo

1. Create the new `appstein` repo under the owner's GitHub account.
2. Move `docs/superpowers/specs/2026-09-29-appstein-design.*`, `reports/` and `research_notes/` into the new repo's `docs/`.
3. Set up graphify in the new repo before writing code.
4. Archive the old `fluttercraft` repo with a README pointing to Appstein. The uncommitted work on `feature/v0.1.3-tui` stays there for reference; nothing is carried over as code.
5. Add a deprecation note to the PyPI `fluttercraft` project page pointing to Appstein, at the first published release.

---

## 21. Visual verification (M2, recorded here so it isn't lost)

- **Golden matrix from Widget Previews** (stable in Flutter 3.47): every `@Preview` rendered in light/dark, text scale 1.0 and 2.0, and LTR/RTL, using CI-stable goldens (e.g. Alchemist's approach).
- **Running app:** agents drive and screenshot it through Marionette MCP or mcp_flutter, then an AI critique step, then the approved state is locked into golden tests. The Dart MCP server's screenshot tool (reported for Dart 3.12, not confirmed in its README) will be verified first.
- **Limit:** goldens detect change, not quality. Aesthetic judgment and screen-reader flow still need AI or human review.

---

## 22. Risks and open questions

| # | Item | Plan |
|---|---|---|
| 1 | Anthropic changes third-party/subscription policy again | M1 runs no agents, so there's no exposure. Re-check before M2 |
| 2 | Codex hook support and MCP config location | Verify in slice 1e; MCP-based fallback + CI enforcement designed in |
| 3 | Project-level enabling of the official Claude Code plugin | Verify in 1e; fallback prints user commands |
| 4 | Duplicate Dart MCP servers (official plugin + ours) | One-server rule (§11.1); verified in 1e |
| 5 | `material_ui` adoption timing (Nov 2026 stable deprecates old imports) | Delta-driven; the `upgrade` migration handles the switch |
| 6 | `gradle_utils.dart` format changes between Flutter versions | Parser tested per supported version; fallback to curated notes |
| 7 | Open Flutter bugs (e.g. #192167, #192111) affect "valid" toolchains | Recorded as curated notes that steer `create` and `toolchain()` |
| 8 | Vide (competitor) evolves | Re-assess before M2; our edge is knowledge + verification + multi-agent support |
| 9 | Antigravity CLI terms not researched | Research before supporting it (post-M1) |
| 10 | "Appstein" trademark/domain; Einstein-estate sensitivity | Trademark + domain check before the first published release (pub.dev or GitHub Releases); pun-only branding |
| 11 | A possible Pro tier | License decided: Apache-2.0 (2026-10-03). Decide on Pro after the M1 benchmark; Pro would be separate, closed code, and the core stays Apache-2.0 |
| 12 | Routes or native values that can't be resolved statically | Marked `unresolved` / `unknown`, never guessed; improve in later slices |
| 13 | Real iOS builds impossible on Windows | Static checks locally; real builds on macOS CI |
| 14 | Minimum supported Flutter version | **Flutter 3.44+** (Dart 3.12, required by the current Dart MCP server; SwiftPM default). Confirmed in slice 1a: CI's `min-sdk` job passes on the newest 3.44 patch (3.44.9 at the time) |
| 15 | The iOS plugin→permission mapping is incomplete at first | Start with the most common plugins; unknown plugins produce an info finding asking the agent to check the plugin's docs |
| 16 | Benchmark results may show no token savings | Report honestly; the correctness gains stand on their own; investigate INDEX/MCP design if tokens rise |
| 17 | M1 is large for one developer who is still learning Dart CLI development | Strict slices (1a–1f) with their own plans; each slice is useful on its own; explain reasoning throughout |
| 18 | `material_ui` breaks with dependencies that expose in-framework Material types | Switch only when every dependency is compatible (§13.1); `upgrade` re-checks each time |
| 19 | Official skills and the plugin stay frozen or keep breaking (e.g. #239) | Pinned version; broken skills overridden; each Appstein release re-checks the pinned plugin against current stable in CI |
| 20 | `appstein_lints` version drifting from the CLI version | Pinned by `integrate`; `doctor` reports a mismatch |
| 21 | Fast verify misses the < 5 s target | Confirmed in 1a: cold analysis misses it, so fast verify uses warm analysis in the long-running MCP process (§9.1). Whether warm analysis meets 5 s is proved in 1d |
| 22 | A Stop hook that keeps failing loops the agent | Loop guard (§5.4): after 3 identical blocks, stop blocking and report to the user |
| 23 | Committed human docs (`docs/app/`) add diff noise or merge conflicts | Deterministic output with no timestamps, rendered once per task (not per edit); conflicts are resolved by re-running `appstein docs` (§6.9) |
| 24 | Doc comments written by agents are vague or restate the code | `appstein-develop` skill teaches what a useful doc comment says; the sample feature from `create` shows the style; the owner judges quality in the M1 sign-off (§18) |

---

## 23. Glossary (for the owner)

- **Agent CLI:** a command-line AI coding tool such as Claude Code or Codex.
- **MCP (Model Context Protocol):** a standard way for agents to call external tools. Our MCP server lets agents ask Appstein questions.
- **Skill:** a short instruction file that agents load when a task needs it.
- **Hook:** a command the agent tool runs automatically at certain moments (after an edit, before stopping).
- **Analyzer / AST:** Dart's own code-understanding engine. The AST is the parsed structure of code, which is what makes our map exact instead of guessed.
- **`fix_data`:** YAML files in the Flutter SDK describing how deprecated APIs map to replacements; `dart fix` uses them.
- **Pack:** a plug-in bundle of knowledge, checks, rules and templates for one stack or one platform.
- **Pub workspace:** a Dart feature that lets one repo hold several related packages.
- **Toolchain matrix:** the set of Gradle/AGP/Kotlin/JDK/SDK versions known to work together for a given Flutter version.
- **Golden test:** a test that compares generated output against a saved, approved copy.
- **AOT executable:** a compiled program that starts instantly, instead of being run through the Dart VM.
- **Doc comment:** a `///` comment above a Dart declaration. `dart doc` turns them into API reference pages, and Appstein uses their first sentence as a summary in the human docs.
- **Mermaid:** a text format for diagrams that GitHub renders as pictures inside Markdown files.
- **Semver:** version numbers of the form MAJOR.MINOR.PATCH, where a MAJOR change means breaking changes.
