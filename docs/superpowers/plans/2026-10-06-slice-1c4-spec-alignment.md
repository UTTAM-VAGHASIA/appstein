# Slice 1c.4: Spec and Code Agree Again Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the small gaps between the spec and the code that the whole-project check of 2026-10-06 found, before more is built on them.

**Architecture:** No new components. Each task changes one existing file and its tests: `where_is` ranking, the MCP server's error replies, `INDEX.md`'s rules and pointers, and the measurement tool. The spec text was caught up first, in its own commit.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 through FVM), `package:test`, `package:dart_mcp` 0.5.2.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` (§5.2, §6.2, §6.3, §6.4, §6.5, §8 as edited for this slice).

**Execution:** native (owner, 2026-10-06), then one whole-branch review on the most capable model.

## Global Constraints

- Every Dart command runs through `fvm dart`.
- Suites run per package from inside the package folder, plus `fvm dart test` at the repo root.
- `fvm dart format --set-exit-if-changed .` and `fvm dart analyze` stay clean.
- The BOM scan finds nothing before every commit.
- No new platform or stack knowledge outside the packs (principle 3; the existing cases move in 1d).
- `INDEX.md` stays at most 4,500 bytes (§6.3).

## Where this came from

The owner asked for a check of the whole project after 1c.1. All tests passed (1,230) and the real `doctor`, `sync` and MCP server worked on a copy of the fixture app. Three read-only audits compared the code with the spec. They found no large drift, and these gaps:

| # | Gap | Fix |
|---|---|---|
| 1 | `where_is`: a word in 10 or more symbol names hides the feature, route and file | Task 1 |
| 2 | `where_is`: the typo rule matched a query word against words of any length (`list` ≈ `lib`) | Task 1 |
| 3 | MCP error replies said nothing about freshness unless it was stale | Task 2 |
| 4 | `INDEX.md` named `verify()`, `package_check()`, `decisions()` and `memory_read()`, which the server doesn't offer yet | Task 3 |
| 5 | The router-edit timing was measured but not held to 2 s; the `measure` job had no time limit | Task 4 |
| 6 | The spec text was behind the code in five places | Done in the spec commit |

**Owner decisions (2026-10-06):**

1. `where_is` shows the best feature, route and file, then the best of the rest; a typo match needs both words to have 4 or more letters.
2. One fix slice now, before 1c.2.
3. The platform and stack knowledge outside the packs (`mcp/toolchain_report.dart`, `feature_query.dart`, `route_query.dart`, `index/`) moves in 1d. Until then, none is added.
4. After this slice, a small unpublished trial: 3–4 tasks with and without Appstein, run by the owner.
5. All eight spec wordings approved.

## Review Focus

- A query that matches no feature, route or file: the ten results are the ten best symbols, as before.
- A query whose best feature, route or file is already in the top ten by score: nothing is listed twice, and the list is still ten long.
- A query with fewer than ten matches: every match is listed once.
- An error reply after a rebuild: the text says what was rebuilt.
- An `INDEX.md` cut to its budget when the pointer tools don't exist: the pointer names the file, and the text still fits.

---

### Task 1: `where_is` shows the best of each kind, and typo matches need 4 letters on both sides

**Files:**
- Modify: `packages/appstein_engine/lib/src/mcp/where_is.dart`
- Test: `packages/appstein_engine/test/mcp/where_is_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `whereIs` keeps its signature. `matches` holds at most `whereIsLimit` entries: the best match of kind `feature`, `route` and `file` when there is one, then the highest-scoring matches that remain, all sorted by score, then name, then file.

- [ ] **Step 1: Write the failing tests.** In `where_is_test.dart`: (a) a map where twelve symbols hold the word `booking`, plus a `booking` feature, a `/booking` route and a `lib/ui/booking/…` file: the result has ten matches, holds one of each of `feature`, `route` and `file`, and seven symbols, in score order; (b) the best route already in the top ten is listed once; (c) with three matches in all, three are listed; (d) the query `list` gives no reason that says it is close to `lib`, and `logn` is still close to `login`.
- [ ] **Step 2: Run them and see them fail.** `fvm dart test test/mcp/where_is_test.dart` from `packages/appstein_engine`.
- [ ] **Step 3: Implement.** In `score`, skip a candidate word shorter than 4 letters in the fuzzy loop. After sorting, pick the first match of each of the kinds `feature`, `route` and `file`, fill up to `whereIsLimit` with the best matches not yet picked, and sort the picked list with `_compare`.
- [ ] **Step 4: Run the file again; all pass.**
- [ ] **Step 5: Commit.**

### Task 2: An error reply states its freshness

**Files:**
- Modify: `packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart` (`_refuse`)
- Test: `packages/appstein_engine/test/mcp/appstein_mcp_server_test.dart`

**Interfaces:**
- Consumes: `FreshnessReport.sentence`.
- Produces: every error reply's text is `'$message ${freshness.sentence}'`.

- [ ] **Step 1: Change the test that pins the old behaviour** (an error with current knowledge has only the message) to expect the freshness sentence, and add one for an error after a rebuild.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Implement:** `_refuse` always appends the sentence.
- [ ] **Step 4: Run the file; all pass.**
- [ ] **Step 5: Commit.**

### Task 3: `INDEX.md` names only the tools the server offers

**Files:**
- Modify: `packages/appstein_engine/lib/src/index/index_document.dart`
- Test: `packages/appstein_engine/test/index/index_document_test.dart`, `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`

**Interfaces:**
- Consumes: `mcpToolNames` from `mcp/appstein_mcp_server.dart`.
- Produces: `IndexInputs.tools` (a `Set<String>`, default `mcpToolNames`). The rule "Run `verify()`…" is written only with `verify` in it; the dependency rule names `package_check()` only with `package_check` in it, and otherwise says "a well-maintained package"; the pointers for hidden decisions and current work name `decisions()` and `memory_read()` when offered, and otherwise `.appstein/decisions/` and `.appstein/memory/current.md`.

- [ ] **Step 1: Write the failing tests:** with the default tools, the text has no `verify()`, `package_check()`, `decisions()` or `memory_read()`, and the cut pointers name the files; with all four tools given, the text is what it was before this slice.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run both test files; update the expectations that pinned the old text.**
- [ ] **Step 5: Commit.**

### Task 4: The router edit is held to 2 s, and the `measure` job has a time limit

**Files:**
- Modify: `tool/measure_sync.dart`, `.github/workflows/ci.yml`
- Test: `test/` at the repo root, where `measure_sync` has tests; otherwise a run of the tool.

- [ ] **Step 1:** Add the router row to `missed` with the same 2 s limit as the view model row.
- [ ] **Step 2:** Give the `measure` job `timeout-minutes: 30`.
- [ ] **Step 3:** Run `fvm dart run tool/measure_sync.dart` as CI does; it exits by itself with code 0 and the router row under 2 s.
- [ ] **Step 4:** `fvm dart run tool/gen_docs.dart` (the CI page lists the jobs).
- [ ] **Step 5: Commit.**

### Task 5: Guide pages, full check

- [ ] Update `docs/guide/mcp-server.md` (where_is ranking, error replies), the INDEX.md page and the CI page for what changed.
- [ ] `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`.
- [ ] All four suites, analyze, format, `dependency_validator` per package, the BOM scan.
- [ ] Commit.

## Carried to later slices

- **1d:** move the platform and stack knowledge out of `mcp/toolchain_report.dart`, `mcp/feature_query.dart`, `mcp/route_query.dart` and `index/` into the packs (principle 3). Remove `IndexInputs.tools`' fallbacks as each tool arrives.
- **1c.2:** `decisions()` and `memory_read()` join `mcpToolNames`, and `INDEX.md` names them again by itself.
- **1e:** `sync` writes the `appstein_lints:` section (spec §5.1, §9.6); already carried from 1b.3.
- **Unassigned:** the MCP reply bodies are maps built in the engine, with only their schemas in the protocol package (principle 4); the `--detect` rows are medians of three, so one slow run passes; no measurement of a rebuild through the MCP server (§8, under 2 s); the `measure` job runs on Ubuntu and Windows only; whether `dart doc --dry-run` fails on every warning (§19.3).
