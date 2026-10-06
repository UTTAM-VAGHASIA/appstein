# Slice 1c.5: Routes Say Where They Redirect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent that asks the `route` tool about a route that redirects learns where it goes, or exactly which line to read, and never stops at "it redirects".

**Architecture:** The official_mvvm pack's route extractor records one more fact per route, `redirectTo`, when the code states it plainly. The `route` MCP tool turns it into the target's path, screen and feature, and for every redirect the map can't resolve it names the file and line.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 through FVM), `package:analyzer`, `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` (§6.5 Routes, §8 `route`, as edited for this slice).

**Execution:** native (owner, 2026-10-06), then one whole-branch review on the most capable model. The owner said to merge when CI is green.

## Global Constraints

- Every Dart command runs through `fvm dart`.
- Suites run per package from inside the package folder, plus `fvm dart test` at the repo root.
- `fvm dart format --set-exit-if-changed .` and `fvm dart analyze` stay clean; the BOM scan finds nothing before every commit.
- Never guess: a redirect target is recorded only when the code states one constant path (spec §6.5).
- The go_router knowledge stays in the pack's extractor. The `route` tool's own go_router matching moves to the pack in 1d (principle 3); this slice adds none.

## Where this came from

The first with/without trial (2026-10-06, four tasks on the fixture app, one run per arm) asked "which screen does `/booking/42` show?". The route `/booking/:id` redirects to `/booking`, which shows `BookingScreen`.

- **Without Appstein** the agent read `router.dart` and answered correctly.
- **With Appstein** the agent called `route`, was told "no screen recorded … It redirects", and answered "it bounces elsewhere". It never opened the file.

An agent stops looking when the map answers, so a map that says less than the code is worse than no map. The tool's old note ("the map records that a route or its router redirects, not where to") was honest, and still a dead end.

## Review Focus

- A redirect with a condition, two returns, a computed path, a function declared elsewhere, or one that returns `null`: nothing is recorded as its target.
- A redirect to a path no route has: the reply gives the path alone, with no invented screen.
- A `routes.json` written before this slice (no `redirectTo` key): it still reads.
- A project already synced: the pack's version changed, so its map is rebuilt and gains the field.
- A router with its own redirect: the reply says where to read it, on every route.

---

### Task 1: The extractor records where a route redirects to

**Files:**
- Modify: `packages/appstein_protocol/lib/src/map/routes_map.dart`
- Modify: `packages/appstein_engine/lib/src/packs/official_mvvm/routes.dart`
- Modify: `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart` (version `1` → `2`)
- Test: `packages/appstein_engine/test/packs/official_mvvm/routes_test.dart`, `packages/appstein_protocol/test/project_map_test.dart`
- Golden: `packages/appstein_engine/test/fixtures/apps/goldens/routes.json.golden`

**Interfaces:**
- Produces: `MapRoute.redirectTo` (`String?`), written as `redirectTo` in `routes.json` and read as null when the key is absent.

- [ ] **Step 1: Write the failing tests:** the fixture's `/booking/:id` has `redirectTo: '/booking'`; a new router file with ten routes covers a literal, a constant, a joined string, a block body with one return (all recorded) and a condition, two returns, a function reference, a computed path, a `null` return and no redirect (none recorded); the protocol round trip, and a map without the key.
- [ ] **Step 2: Run them; they fail** (no `redirectTo` parameter).
- [ ] **Step 3: Implement:** `_redirectTo` reads `redirect:` when it is a function literal with a single plain return (`singleReturn`) of a constant string (`constantString`).
- [ ] **Step 4: Regenerate the routes golden** with `APPSTEIN_UPDATE_GOLDENS=1` and review the diff: one `"redirectTo": "/booking"`, seven `"redirectTo": null`, nothing else.
- [ ] **Step 5: Run both test files; all pass.**

### Task 2: The `route` tool never ends at "it redirects"

**Files:**
- Modify: `packages/appstein_engine/lib/src/mcp/route_query.dart`
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Test: `packages/appstein_engine/test/mcp/route_query_test.dart`

**Interfaces:**
- Produces, per route in the reply: `redirectsTo` (`{path, screen?, feature?}`) when the map knows the target, with the screen and feature of the route at that path; `redirectHint` (text naming `file:line`) when the route redirects and the map doesn't know where. At the top: `redirectNote` only when a router has its own redirect, naming each such router's `file:line`.

- [ ] **Step 1: Write the failing tests:** `/booking/42` gives `redirectsTo` with `BookingScreen` and feature `booking`, and the summary says so; an unknown redirect gives the hint and the summary names the line; a target no route has gives the path alone; a router redirect gives the note; no router redirect gives none; each reply fits the schema.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the MCP tests; all pass.**

### Task 3: Guide pages, full check

- [ ] Update `docs/guide/project-map.md` (routes) and `docs/guide/mcp-server.md` (`route`).
- [ ] `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`.
- [ ] All four suites, analyze, format, `dependency_validator`, the BOM scan.
- [ ] Commit.

## Notes from execution

Built natively on `slice-1c5`, 2026-10-06, then one whole-branch review on Opus and one fix pass. PR #6. The owner said to merge when CI is green.

**Commits:** `9a79df2` the slice (spec, plan, code, guide); the review's fixes in the commit after it.

**Rulings:**
- **One commit for Tasks 1–3**, with the spec edit and the plan: the slice is about 150 lines of code. Cost if wrong: a coarser history.
- **`redirectNote` is no longer required** in the `route` result: it is present only when a router redirects. The old fixed sentence was the dead end this slice removes. Cost if wrong: a client that required the key; there is none.
- **The pack's version went from 1 to 2** to rebuild existing maps, since the map's input hash holds the packs' versions and not the extractor's code. Cost if wrong: one rebuild per project.

**What the review caught (fixed, each test-first):**
- **Important:** a redirect to a route that has a redirect of its own was reported with that route's screen as the answer (`/` → `/home`, where `/home` checks sign-in), or as a bare "It redirects to `/b`" when `/b` only redirects: the same dead end, one hop later. `redirectsTo` now carries the target's `redirect`, `file` and `line`, and the summary says the path may not end there.
- **Important:** a route with both a builder and a redirect had its screen stated as the answer. The summary now says the screen is shown only when the redirect lets the path through.
- **Minor:** the pack-version test would have passed without the version in the map's hash; it now checks that `map/routes.json` is what was out of date. The tool's description and the visual page's card still said "whether it redirects".

**Checked:** 1,243 tests (root 225, protocol 66, engine 874 with 7 skipped, CLI 59, lints 19); analyze, format, `dependency_validator`, the guide check and the BOM scan. The routes golden changed by one `"redirectTo": "/booking"` and seven `"redirectTo": null`.

## Carried to later slices

- **From the review (minor, left):**
  - the target path is matched by exact text, so a target with a query (`/login?from=x`), a trailing slash, a concrete path for a pattern (`/booking/42`) or a relative path gets no screen. Never wrong, only weaker;
  - a route doesn't record which router it belongs to, so with two routers a route is told about a redirect of the other one;
  - `{ if (x) throw …; return '/b'; }` is recorded as `/b`: only `return`s are counted;
  - in go_router a parent's redirect also runs for its children; `route` on a child doesn't mention the parent's. Unverified here; check it in 1d.
- **1d:** a router's own `redirect:` is still only "it has one; read it". Its condition (signed in or not) can't be reduced to one path. If the verifier or the docs renderer needs more, record the paths it can return.
- **1d:** `route_query.dart`'s go_router pattern matching moves into the pack with the other platform and stack knowledge (carried from 1c.4).
- **Unassigned:** a redirect that returns `state.namedLocation('name')` or `context.namedLocation(...)` could be resolved through the route's `name:`; today it is "not known".
- **The trial's other lessons** (not code): INDEX.md and the tool descriptions are a fixed cost per session; a 30-file app understates what the map saves; the next trial needs a larger app, newer API changes and three runs per arm.
