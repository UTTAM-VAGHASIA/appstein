# Slice 1d.1: Verify Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein verify [--fast|--full] [--format text|json]` and the `verify` MCP tool: the frame every later check plugs into, with the checks that only read files Appstein already has.

**Architecture:** A `VerifyCheck` has stable IDs, a mode and returns `Finding`s. The engine contributes its checks; packs contribute theirs through `Pack.checks` and `Pack.decisionChecks`. `runVerify` refreshes the knowledge, reads it once under the lock, runs the checks of the chosen mode, applies severity overrides and suppressions, and returns a `VerifyResult`. The CLI and the MCP tool both call `runVerify`.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 through FVM), `package:args`, `package:dart_mcp` 0.5.2, `package:glob`, `package:yaml`, `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`: §5.3, §6.7, §6.8, §6.9, §7, §8, §9 (opening, §9.2, §9.3, §9.5, §9.7), §10.

## Owner decisions (2026-10-06)

1. 1d is six slices: 1d.1 verify core, 1d.2 code checks and fast verify, 1d.3 lint rules, 1d.4 package gate, 1d.5 Android, 1d.6 iOS.
2. When the knowledge can't be brought up to date: `knowledge.stale` is an **error**; checks that read the map are not run and are named; the others run.
3. With neither `--fast` nor `--full`, `verify` runs the full checks.
4. A suppression that hides nothing is the warning `suppression.unused`, in full mode only.
5. Approach A: a `VerifyCheck` interface; packs contribute checks.
6. The stack knowledge in `feature_query.dart`, `route_query.dart` and `index/` moves in 1d.3; `toolchain_report.dart` moves in 1d.5 and 1d.6. Nothing new is added outside the packs here.
7. All nine deferred minors from 1c.3 are fixed in this slice.

## Global Constraints

- Every Dart command runs through FVM: `fvm dart …`, `fvm flutter …`.
- Test suites run per package, from inside the package folder, plus the repo-root suite (`fvm dart test test` at the root).
- Tests first: each test is seen failing before the code that makes it pass.
- Files are read, written and searched with the Read, Edit, Write, Grep and Glob tools, never shell `cat`, `sed`, `grep` or redirection.
- No BOM in any Dart file: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` prints nothing before each commit. A Dart string that needs U+FEFF or U+FFFD uses `String.fromCharCode`.
- The engine core never imports a pack (§5.1). Stack and platform knowledge lives in its pack (principle 3): `stack.provider` and its package list are in `official_mvvm`.
- Fast checks only report; no check in this slice writes a project file (§9.1).
- Check IDs are stable once released (§9.3): `knowledge.stale`, `docs.stale`, `decision.drift`, `decision.unreadable`, `decision.duplicate`, `memory.lessons_long`, `verify.test_required`, `suppression.no_reason`, `suppression.unknown_check`, `suppression.unused`.
- Paths in findings are project-relative with `/`, on every OS.
- Every public API has a `///` comment; `fvm dart doc --dry-run` passes in each package.
- Commits carry the `Co-Authored-By` and `Claude-Session` trailers and a `Docs-Checked:` trailer for each guide page that covers changed code and is still right.
- Not in this slice: `--files`, `--hook`, exit code 2, the Dart `// appstein:ignore` comments, analyze/fix/format/test checks (1d.2); lint rules (1d.3); the package gate (1d.4); Android and iOS checks (1d.5, 1d.6).

## Review Focus

1. **A project that never ran `appstein docs`.** `verify` reports one `docs.stale` warning per page (missing), exits 0, and writes nothing. Test in Task 5.
2. **A decision file with CRLF line endings or a BOM.** The finding's line number is still the line of `checks:` or `paths:` as an editor shows it. Test in Task 7.
3. **A suppression `path` written with `\`, an absolute path, or `..`.** `appstein.yaml` is refused with the line (exit 3), never matched loosely. Test in Task 1.
4. **Another Appstein process holds the knowledge lock.** `verify` waits no longer than the lock timeout, reports `knowledge.stale`, names the map checks as not run, and exits 1. Test in Task 3.
5. **A project with no `appstein.yaml` and no `.appstein/`.** `verify` uses the defaults, syncs fully first, and reports findings; it never asks for a setup step. Test in Task 9.

## File Structure

**`appstein_protocol`**
- Create `lib/src/verify/finding.dart`: `Finding`.
- Create `lib/src/verify/verify_result.dart`: `CheckNotRun`, `VerifyResult`.
- Modify `lib/src/config/appstein_config.dart`: `SuppressionEntry`, `AppsteinConfig.suppressions`.
- Modify `lib/src/mcp/tool_schemas.dart`: `verifyInput`, `verifyResult`.
- Modify `lib/appstein_protocol.dart`: exports.

**`appstein_engine`**
- Modify `lib/src/config/config_loader.dart`: `suppressions:` and the `docs.path` rule.
- Create `lib/src/knowledge/knowledge_refresh.dart`: `KnowledgeRefresh`, `refreshKnowledge`.
- Create `lib/src/verify/verify_check.dart`: `VerifyMode`, `VerifyCheck`, `VerifyContext`, `VerifyCheckError`.
- Create `lib/src/verify/decision_check.dart`: `DecisionCheck`.
- Create `lib/src/verify/suppressions.dart`: `applySuppressions`.
- Create `lib/src/verify/verify_run.dart`: `runVerify`, `unsuppressibleIds`.
- Create `lib/src/verify/engine_checks.dart`: `engineChecks`, `engineDecisionChecks`.
- Create `lib/src/verify/checks/docs_stale_check.dart`, `decisions_check.dart`, `paths_exist_check.dart`, `lessons_long_check.dart`, `test_required_check.dart`.
- Create `lib/src/docs/docs_prepare.dart`: `prepareDocs` (moved out of `runDocs`).
- Modify `lib/src/docs/docs_run.dart`, `docs_folder.dart`, `docs_renderer.dart`, `markdown_text.dart`, pages as the minors need.
- Modify `lib/src/packs/pack.dart`: `checks`, `decisionChecks`.
- Create `lib/src/packs/official_mvvm/stack_provider_check.dart`; modify `official_mvvm_pack.dart`, `android_pack.dart`, `ios_pack.dart`.
- Create `lib/src/mcp/verify_tool.dart`; modify `appstein_mcp_server.dart`, `tool_names.dart`.
- Modify `lib/appstein_engine.dart`: exports.

**`appstein_cli`**
- Create `lib/src/verify_command.dart`: `VerifyCommand`, `formatVerify`, `verifyExitCode`.
- Modify `lib/src/runner.dart`, `lib/src/mcp_command.dart`, `lib/appstein_cli.dart`.

**Repo**
- Modify `tool/measure_sync.dart`, `test/generators_test.dart`.
- Create `docs/guide/verify.md`, `docs/guide/how-to/add-a-check.md`; update `cli.md`, `mcp-server.md`, `architecture.md`, `human-docs.md`, `README.md`, `ci.md`, the packs page.

---

### Task 1: Protocol types and `appstein.yaml`

**Files:**
- Create: `packages/appstein_protocol/lib/src/verify/finding.dart`, `packages/appstein_protocol/lib/src/verify/verify_result.dart`
- Modify: `packages/appstein_protocol/lib/src/config/appstein_config.dart`, `packages/appstein_protocol/lib/appstein_protocol.dart`, `packages/appstein_engine/lib/src/config/config_loader.dart`
- Test: `packages/appstein_protocol/test/verify/finding_test.dart`, `packages/appstein_protocol/test/verify/verify_result_test.dart`, `packages/appstein_engine/test/config/config_loader_test.dart` (add cases)

**Interfaces:**
- Produces:

```dart
/// One thing `verify` found (spec §9.3).
final class Finding {
  const Finding({
    required this.id,
    required this.severity,
    this.file,
    this.line,
    required this.message,
    this.fixHint,
    this.knowledgeRef,
    this.pack,
    this.docs,
  });
  factory Finding.fromJson(Map<String, Object?> json);
  final String id;
  final Severity severity;
  final String? file;      // project-relative, with `/`; null for the project
  final int? line;         // 1-based
  final String message;
  final String? fixHint;
  final String? knowledgeRef;
  final String? pack;
  final String? docs;
  Finding withSeverity(Severity severity);
  Finding withPack(String pack);
  Map<String, Object?> toJson();   // null fields are left out
}

/// A check that did not run, and why.
final class CheckNotRun {
  const CheckNotRun({required this.id, required this.reason});
  final String id;
  final String reason;
  Map<String, Object?> toJson();
}

/// What one `verify` run found (spec §9.3).
final class VerifyResult {
  const VerifyResult({
    required this.findings,
    this.suppressed = 0,
    this.notRun = const [],
  });
  factory VerifyResult.fromJson(Map<String, Object?> json);
  final List<Finding> findings;    // sorted: see `sortFindings`
  final int suppressed;
  final List<CheckNotRun> notRun;  // sorted by id
  int get errors;
  int get warnings;
  int get info;
  Map<String, Object?> toJson();   // {findings, summary: {errors, warnings, info}, suppressed, notRun}
}

/// Findings in the order every output uses: findings without a file
/// first, then by file; inside a file by severity (error, warning, info),
/// then line (none first), then id, then message.
List<Finding> sortFindings(Iterable<Finding> findings);

/// One entry of `suppressions:` in `appstein.yaml` (spec §9.7).
final class SuppressionEntry {
  const SuppressionEntry({required this.id, required this.path, this.reason, required this.line});
  final String id;
  final String path;     // a file or glob from the project root, with `/`
  final String? reason;  // null when missing or blank: that is a finding, not a config error
  final int line;        // 1-based line of the entry in appstein.yaml
  Map<String, Object?> toJson();   // {id, path, reason}
}
```

`AppsteinConfig` gains `final List<SuppressionEntry> suppressions` (default `const []`), and `toJson` gains `'suppressions'`.

- [ ] **Step 1: Write the failing protocol tests**

`finding_test.dart` checks:
- `toJson` of the §9.3 example gives exactly the spec's keys and values, in the order `id, severity, file, line, message, fixHint, knowledgeRef, pack, docs`;
- a finding with only `id`, `severity`, `message` gives exactly those three keys;
- `Finding.fromJson(finding.toJson())` round-trips both;
- `fromJson` throws a `FormatException` naming the field for a missing `id`, a `severity` that isn't one of the three words, and a `line` that isn't an integer;
- `withSeverity` and `withPack` change only that field.

`verify_result_test.dart` checks:
- `sortFindings` on a shuffled list gives: file-less first; then files alphabetically; in a file error before warning before info; then no-line before line 3 before line 12; then id;
- `errors`, `warnings`, `info` count by severity;
- `toJson` gives `{'findings': [...], 'summary': {'errors': 1, 'warnings': 2, 'info': 0}, 'suppressed': 1, 'notRun': [{'id': 'docs.stale', 'reason': '…'}]}` and `fromJson` round-trips it.

- [ ] **Step 2: Run them to see them fail**

Run (in `packages/appstein_protocol`): `fvm dart test test/verify`
Expected: FAIL, the files under `lib/src/verify/` don't exist.

- [ ] **Step 3: Write `finding.dart` and `verify_result.dart`, export them**

Use `JsonFields` (`lib/src/json_fields.dart`) for `fromJson`, as `DepsMap` does. `toJson` leaves null fields out with collection-`if`. Add both files and `SuppressionEntry` to `lib/appstein_protocol.dart`.

- [ ] **Step 4: Run the protocol tests**

Run: `fvm dart test` in `packages/appstein_protocol`. Expected: all pass.

- [ ] **Step 5: Write the failing config tests**

Add to `packages/appstein_engine/test/config/config_loader_test.dart`:

```dart
group('suppressions', () {
  test('reads id, path, reason and the line of each entry', () {
    final config = parseConfig(
      'suppressions:\n'
      '  - id: decision.drift\n'
      '    path: .appstein/decisions/0002-state.md\n'
      '    reason: Riverpod is being trialled in one feature.\n'
      '  - id: verify.test_required\n'
      '    path: lib/ui/**\n',
    );
    expect(config.suppressions, hasLength(2));
    expect(config.suppressions[0].id, 'decision.drift');
    expect(config.suppressions[0].path, '.appstein/decisions/0002-state.md');
    expect(config.suppressions[0].reason, 'Riverpod is being trialled in one feature.');
    expect(config.suppressions[0].line, 2);
    expect(config.suppressions[1].reason, isNull);
    expect(config.suppressions[1].line, 5);
  });

  test('a blank reason is read as no reason', () {
    final config = parseConfig(
      'suppressions:\n  - id: docs.stale\n    path: docs/app/**\n    reason: "  "\n',
    );
    expect(config.suppressions.single.reason, isNull);
  });

  test('normalizes ./ and keeps globs', () {
    final config = parseConfig(
      'suppressions:\n  - id: docs.stale\n    path: ./docs/app/*.md\n    reason: x\n',
    );
    expect(config.suppressions.single.path, 'docs/app/*.md');
  });

  for (final (yaml, message) in [
    ('suppressions: nope\n', 'suppressions must be a list'),
    ('suppressions:\n  - nope\n', 'Every entry in suppressions must be a map'),
    ('suppressions:\n  - path: a\n    reason: b\n', 'needs an id'),
    ('suppressions:\n  - id: Bad\n    path: a\n', '"Bad" is not a check ID'),
    ('suppressions:\n  - id: docs.stale\n    reason: b\n', 'needs a path'),
    ('suppressions:\n  - id: docs.stale\n    path: C:\\docs\n', 'must be relative'),
    ('suppressions:\n  - id: docs.stale\n    path: /docs\n', 'must be relative'),
    ('suppressions:\n  - id: docs.stale\n    path: ../x\n', 'inside the project'),
    ('suppressions:\n  - id: docs.stale\n    path: docs\\\\app\n', 'must use /'),
    ('suppressions:\n  - id: docs.stale\n    path: "[x"\n', 'is not a valid pattern'),
    ('suppressions:\n  - id: docs.stale\n    path: a\n    why: b\n', 'Unknown key "why"'),
  ]) {
    test('refuses: $message', () {
      expect(
        () => parseConfig(yaml),
        throwsA(isA<ConfigException>()
            .having((e) => e.message, 'message', contains(message))
            .having((e) => e.line, 'line', isNotNull)),
      );
    });
  }
});

group('docs.path', () {
  for (final path in ['.appstein', '.appstein/docs', '.git/x', '.dart_tool', 'build/docs', 'lib', 'lib/docs', 'test']) {
    test('refuses $path', () {
      expect(
        () => parseConfig('docs:\n  path: $path\n'),
        throwsA(isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('docs.path must not be inside .appstein, .git, .dart_tool, build, lib or test'),
        )),
      );
    });
  }
  test('still accepts docs/lib and library', () {
    expect(parseConfig('docs:\n  path: docs/lib\n').docs.path, 'docs/lib');
    expect(parseConfig('docs:\n  path: library\n').docs.path, 'library');
  });
});
```

Also add `'suppressions'` to the existing test of the top-level allowed keys, if one lists them.

- [ ] **Step 6: Run to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/config/config_loader_test.dart`
Expected: FAIL with `Unknown key "suppressions"` and the `docs.path` cases passing through.

- [ ] **Step 7: Implement in `config_loader.dart` and `appstein_config.dart`**

- Add `'suppressions'` to the top-level `_checkKeys` list and a `_suppressions(top.nodes['suppressions'])` reader.
- Each entry: a `YamlMap` with keys `id`, `path`, `reason` only. `id` must match `_checkIdPattern`. `path`: text, not blank, `\` refused ("must use /"), absolute refused with both `p.posix.isAbsolute` and `p.windows.isAbsolute`, normalized with `p.posix.normalize`; `.`, `..` and a `../` prefix refused ("must be a path inside the project"); `Glob(path, context: p.posix)` in a `try` and a `FormatException` refused ("is not a valid pattern"). `reason`: text or absent; `trim()`; empty becomes null. `line` is `entry.span.start.line + 1`.
- `docs.path`: after normalizing, refuse when the first segment is one of `.appstein`, `.git`, `.dart_tool`, `build`, `lib`, `test`.

- [ ] **Step 8: Run both packages' suites**

Run: `fvm dart test` in `packages/appstein_protocol`, then in `packages/appstein_engine`. Expected: all pass.

- [ ] **Step 9: Commit**

`feat: findings, the verify result and suppressions in appstein.yaml`

---

### Task 2: `refreshKnowledge`, shared by `docs` and `verify`

**Files:**
- Create: `packages/appstein_engine/lib/src/knowledge/knowledge_refresh.dart`
- Modify: `packages/appstein_engine/lib/src/docs/docs_run.dart`, `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_refresh_test.dart`

**Interfaces:**
- Produces:

```dart
/// Whether the knowledge is up to date, and when it isn't, why (spec §9).
final class KnowledgeRefresh {
  const KnowledgeRefresh.current() : problem = null, fixHint = null;
  const KnowledgeRefresh.failed(String this.problem, {this.fixHint});
  /// From the MCP server's freshness check, which already ran the sync.
  factory KnowledgeRefresh.fromFreshness(FreshnessReport freshness);
  final String? problem;   // words that follow "because"; null when current
  final String? fixHint;   // a sentence; null when [problem] says enough
  bool get ok => problem == null;
}

/// Brings the knowledge of [projectRoot] up to date as `sync --detect` does.
/// It never throws for the project's own state: a failed sync, a busy lock, a
/// write that failed and a skipped project map each give a `failed` result.
Future<KnowledgeRefresh> refreshKnowledge(
  KnowledgeSync sync,
  String projectRoot, {
  String? dartSdkPath,
  required String runAgain,   // such as 'Then run `appstein docs` again.'
});
```

- [ ] **Step 1: Write the failing tests**

`knowledge_refresh_test.dart`, with `copyFixtureApp()`, `fakeFlutter()`, `knowledgeSync(...)` and `holdLock` from the existing support files (as `docs_run_test.dart` uses them):
- a healthy fixture gives `ok`;
- a Flutter root that doesn't exist gives `failed` with the `SyncException`'s problem and fix hint;
- with the lock held by another process and `lockTimeout: 200 ms`, it gives `failed('another Appstein process holds the knowledge lock')` within 5 s;
- a `pub get` the fake runner fails gives `failed` whose problem starts `the project map is missing (` and whose hint names `flutter pub get`;
- `KnowledgeRefresh.fromFreshness`: `current` gives ok; `rebuilt` without `mapSkipped` gives ok; `rebuilt` with `mapSkipped: 'x.'` gives `failed('the project map is missing (x)')`; `stale(problem, fixHint)` gives `failed` with both.

Read `packages/appstein_protocol/lib/src/mcp/freshness_report.dart` first for the exact field names.

- [ ] **Step 2: Run to see them fail**

Run: `fvm dart test test/knowledge/knowledge_refresh_test.dart`. Expected: FAIL, the file doesn't exist.

- [ ] **Step 3: Move the code**

Move the first block of `runDocs` (the `try` around `sync.detect` and the `report.map?.skipped` branch, `docs_run.dart` lines 134–160) into `refreshKnowledge`, with `runAgain` in place of `_runAgain` and the lock message as a `failed` result. `runDocs` becomes:

```dart
final refresh = await refreshKnowledge(sync, projectRoot, dartSdkPath: dartSdkPath, runAgain: _runAgain);
if (refresh.problem case final problem?) {
  return refused(problem, fixHint: refresh.fixHint ?? (problem == lockBusyProblem ? 'Run `appstein docs` again when it has finished.' : null));
}
```

Keep every message `runDocs` gives today byte for byte; `docs_run_test.dart` and the CLI's `docs_command_test.dart` are the proof.

- [ ] **Step 4: Run the engine and CLI suites**

Run: `fvm dart test` in `packages/appstein_engine`, then in `packages/appstein_cli`. Expected: all pass, with no docs test changed.

- [ ] **Step 5: Commit**

`refactor: one knowledge refresh for docs and verify`

---

### Task 3: The frame: checks, context and `runVerify`

**Files:**
- Create: `packages/appstein_engine/lib/src/verify/verify_check.dart`, `packages/appstein_engine/lib/src/verify/verify_run.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/verify/verify_run_test.dart`, `packages/appstein_engine/test/verify/support/verify_support.dart`

**Interfaces:**
- Consumes: `Finding`, `VerifyResult`, `CheckNotRun`, `sortFindings` (Task 1); `KnowledgeRefresh`, `refreshKnowledge` (Task 2).
- Produces:

```dart
/// When a check runs (spec §9.1, §9.2).
enum VerifyMode {
  fast,  // after every change; a fast check also runs in full mode
  full,  // at "done"
}

/// What a check may read: one reading of the knowledge, taken under the lock.
final class VerifyContext {
  const VerifyContext({
    required this.projectRoot,
    required this.config,
    required this.packs,
    required this.knowledge,
    required this.decisions,
  });
  final String projectRoot;
  final AppsteinConfig config;
  final List<Pack> packs;
  final KnowledgeSnapshot knowledge;
  final DecisionSet decisions;
}

/// One check of `verify` (spec §9).
abstract interface class VerifyCheck {
  /// Every finding ID it can report; the first names the check in "not run".
  List<String> get ids;
  /// `fast` runs in both modes, `full` only in full mode.
  VerifyMode get mode;
  /// Whether it reads the project map. Such a check isn't run when the
  /// knowledge is stale.
  bool get needsMap;
  Future<List<Finding>> run(VerifyContext context);
}

/// A check threw: Appstein failed (exit 3, spec §9.5).
final class VerifyCheckError implements Exception {
  VerifyCheckError(this.checkId, this.error, this.stackTrace);
  final String checkId;
  final Object error;
  final StackTrace stackTrace;
  @override String toString() => 'The check `$checkId` failed: $error';
}

/// The IDs no suppression and no severity override changes (spec §9.7).
const unsuppressibleIds = {
  'knowledge.stale',
  'suppression.no_reason',
  'suppression.unknown_check',
  'suppression.unused',
};

/// Runs `verify` on the project at [projectRoot] (spec §9).
///
/// [checks] is every check of the project, the engine's and its packs',
/// each with the pack that contributed it (null for the engine).
/// [refreshed] is a refresh the caller already ran (the MCP server's);
/// when null, this refreshes the knowledge itself.
Future<VerifyResult> runVerify({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSync sync,
  required VerifyMode mode,
  required List<({VerifyCheck check, String? pack})> checks,
  KnowledgeRefresh? refreshed,
  String? dartSdkPath,
});
```

`runVerify`, in order:
1. `refresh = refreshed ?? await refreshKnowledge(sync, projectRoot, dartSdkPath: dartSdkPath, runAgain: 'Then run `appstein verify` again.')`.
2. Try `KnowledgeStore(projectRoot).locked(body, timeout: sync.lockTimeout)`. On `KnowledgeLockTimeout`, run `body` without the lock, with `refresh` replaced by `KnowledgeRefresh.failed('another Appstein process holds the knowledge lock', fixHint: 'Run `appstein verify` again when it has finished.')` (knowledge files are replaced in one step, so a reader without the lock sees whole files).
3. In `body`: `snapshot = KnowledgeSnapshot(projectRoot)`. `mapProblem` is `refresh.problem`, or the first `problem` among `snapshot.sdk`, `features`, `symbols`, `routes`, `layers`, `deps`, `native` (with the fix hint 'Run `appstein sync` in the project to see why.').
4. When `mapProblem` is set, add `Finding(id: 'knowledge.stale', severity: Severity.error, message: 'The knowledge could not be brought up to date: $problem.', fixHint: …, knowledgeRef: '.appstein/state.json')` (no trailing double period when `problem` ends with one).
5. For each check whose mode is selected (`mode == full` selects all; `mode == fast` selects `VerifyMode.fast` checks): when `check.needsMap && mapProblem != null`, add `CheckNotRun(id: check.ids.first, reason: 'the project map is not up to date')`; otherwise `await check.run(context)` inside `try`; any thrown object becomes `throw VerifyCheckError(check.ids.first, error, stack)`. A finding whose `id` isn't in `check.ids` is a `VerifyCheckError` too ("reported `x`, which it does not declare"). Stamp `withPack(pack)` when the finding has none and the check came from a pack.
6. Apply `config.verify.severity[finding.id]` to every finding whose id isn't in `unsuppressibleIds`.
7. Apply suppressions (Task 4; until then, pass findings through).
8. Return `VerifyResult(findings: sortFindings(...), suppressed: …, notRun: sorted by id)`.

- [ ] **Step 1: Write the test support**

`verify_support.dart`:

```dart
/// A check for tests: reports [findings], or throws [error].
final class FakeCheck implements VerifyCheck {
  FakeCheck(this.ids, {this.mode = VerifyMode.full, this.needsMap = false, this.findings = const [], this.error});
  @override final List<String> ids;
  @override final VerifyMode mode;
  @override final bool needsMap;
  final List<Finding> findings;
  final Object? error;
  int runs = 0;
  VerifyContext? seen;
  @override
  Future<List<Finding>> run(VerifyContext context) async {
    runs++;
    seen = context;
    if (error case final error?) throw error;
    return findings;
  }
}

Finding finding(String id, {Severity severity = Severity.warning, String? file, int? line, String message = 'm'}) =>
    Finding(id: id, severity: severity, file: file, line: line, message: message);
```

- [ ] **Step 2: Write the failing tests**

`verify_run_test.dart`, on `copyFixtureApp()` with the real `knowledgeSync(...)` harness (as `docs_run_test.dart`), a helper `run({mode, checks, config, refreshed, flutterRoot, lockTimeout})`:

- **modes:** a fast and a full fake check; `mode: fast` runs only the fast one (`runs` is 1 and 0); `mode: full` runs both.
- **one reading:** two checks see the identical `VerifyContext` instance; `context.projectRoot`, `config` and `packs` are the ones passed.
- **healthy project:** no `knowledge.stale`, `notRun` empty.
- **the sync fails** (`flutterRoot` that doesn't exist): one `knowledge.stale` error with no file, message starting `The knowledge could not be brought up to date: `, a fix hint; the `needsMap` check has `runs == 0` and is in `notRun` with reason `the project map is not up to date`; the other check ran.
- **a damaged map file** (after one good run, write `{` into `.appstein/map/features.json`, and pass `refreshed: const KnowledgeRefresh.current()` so the sync doesn't repair it): `knowledge.stale` names `` `.appstein/map/features.json` is damaged ``; the map check is not run.
- **`refreshed` given:** with `refreshed: KnowledgeRefresh.failed('x', fixHint: 'Do y.')` the message is `The knowledge could not be brought up to date: x.` and the fake runner saw no `pub get` (the sync did not run).
- **the lock is held** by another process (`holdLock`), `lockTimeout: 200 ms`: returns within 5 s with `knowledge.stale` naming the lock; the map check not run; the other ran.
- **a check throws:** `runVerify` throws a `VerifyCheckError` with `checkId` the check's first id and the original error.
- **an undeclared id:** a check with `ids: ['a.b']` reporting `c.d` throws `VerifyCheckError` whose text names both.
- **pack stamp:** a check registered with `pack: 'android'` reporting a finding without `pack` gets `pack: 'android'`; a finding that names a pack keeps it; an engine check's finding has none.
- **severity overrides:** `config.verify.severity = {'a.b': Severity.error}` raises that finding; `{'knowledge.stale': Severity.info}` leaves `knowledge.stale` an error.
- **order:** findings come back as `sortFindings` orders them; `notRun` by id.

- [ ] **Step 3: Run to see them fail**

Run: `fvm dart test test/verify/verify_run_test.dart`. Expected: FAIL, `verify_run.dart` doesn't exist.

- [ ] **Step 4: Write `verify_check.dart` and `verify_run.dart`; export them**

As specified under Interfaces. `KnowledgeSnapshot` and `DecisionSet` are read once: `VerifyContext(knowledge: snapshot, decisions: readDecisions(projectRoot), …)`.

- [ ] **Step 5: Run the tests**

Run: `fvm dart test test/verify`. Expected: all pass.

- [ ] **Step 6: Commit**

`feat: the verify frame: checks, one reading of the knowledge, knowledge.stale`

---

### Task 4: Suppressions

**Files:**
- Create: `packages/appstein_engine/lib/src/verify/suppressions.dart`
- Modify: `packages/appstein_engine/lib/src/verify/verify_run.dart`
- Test: `packages/appstein_engine/test/verify/suppressions_test.dart`, `packages/appstein_engine/test/verify/verify_run_test.dart` (add cases)

**Interfaces:**
- Consumes: `SuppressionEntry` (Task 1), `unsuppressibleIds`, `VerifyMode` (Task 3).
- Produces:

```dart
/// Applies `suppressions:` (spec §9.7) to [findings].
///
/// [knownIds] is every ID a check of the project can report. `kept` is the
/// findings that stay plus the `suppression.*` findings; `suppressed` is how
/// many were hidden.
({List<Finding> kept, int suppressed}) applySuppressions(
  List<Finding> findings,
  List<SuppressionEntry> entries, {
  required Set<String> knownIds,
  required VerifyMode mode,
});
```

Rules, in this order for each entry:
1. `reason == null`: add `Finding(id: 'suppression.no_reason', severity: error, file: 'appstein.yaml', line: entry.line, message: 'The suppression of `<id>` on `<path>` has no reason, so it hides nothing.', fixHint: 'Add `reason:` saying why this finding is accepted.')`. The entry hides nothing.
2. `id` not in `knownIds`, or in `unsuppressibleIds`: add `suppression.unknown_check` (error, same file and line). Message for an unknown id: ``No check of this project reports `<id>`.`` with `fixHint` ``Did you mean `<closest>`?`` from `closestMatch` (`lib/src/text/edit_distance.dart`) when there is one. Message for an unsuppressible id: `` `<id>` can't be suppressed. `` with fix hint `Remove this entry and fix what the finding reports.` The entry hides nothing.
3. Otherwise it hides every finding with that `id` whose `file` is not null and matches: `Glob(entry.path, context: p.posix).matches(file)`, or `file == entry.path`, or `file` starts with `'${entry.path}/'` (a folder).
4. A valid entry that hid nothing, in `VerifyMode.full` only: add `suppression.unused` (warning, `appstein.yaml`, the line): `The suppression of `<id>` on `<path>` hides no finding.` with fix hint `Remove it, so it can't hide the same finding if it comes back.`

`suppression.*` findings are never hidden by any entry. Matching is case-sensitive on every OS (finding paths come from Appstein and are stable).

- [ ] **Step 1: Write the failing tests**

`suppressions_test.dart`, one test per rule:
- an entry with a reason hides its finding: `kept` empty, `suppressed == 1`;
- it hides only that id (another id on the same file stays) and only that path (same id on another file stays);
- a glob `docs/app/**` hides `docs/app/features/home.md`; a folder path `docs/app` hides it too; a file-less finding is never hidden;
- one entry hiding three findings gives `suppressed == 3`;
- no reason: the finding stays, `suppression.no_reason` is added on `appstein.yaml` at the entry's line, and no `suppression.unused` is added for that entry;
- unknown id `docs.stael` with `knownIds: {'docs.stale'}`: `suppression.unknown_check` whose fix hint is ``Did you mean `docs.stale`?``;
- id `knowledge.stale`: `suppression.unknown_check` saying it can't be suppressed; the `knowledge.stale` finding stays;
- unused, full mode: `suppression.unused` warning at the line; fast mode: nothing;
- an entry for `suppression.unused` itself: `unknown_check`.

Add to `verify_run_test.dart`: a config with one entry hiding a fake check's finding gives `result.suppressed == 1` and no finding; `knownIds` come from every registered check's `ids`, whatever the mode (an entry for a full-only check in fast mode is not `unknown_check`); an override that raises a finding to error and an entry that hides it: it is hidden (overrides first, then suppressions).

- [ ] **Step 2: Run to see them fail**

Run: `fvm dart test test/verify/suppressions_test.dart`. Expected: FAIL, no `suppressions.dart`.

- [ ] **Step 3: Write `suppressions.dart` and call it from `runVerify` step 7**

`knownIds` in `runVerify` is `{for (final c in checks) ...c.check.ids, ...unsuppressibleIds}`.

- [ ] **Step 4: Run the tests**

Run: `fvm dart test test/verify`. Expected: all pass.

- [ ] **Step 5: Commit**

`feat: suppressions with a mandatory reason; unknown and unused ones are reported`

---

### Task 5: Docs folder minors, `prepareDocs`, and `docs.stale`

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/docs_prepare.dart`, `packages/appstein_engine/lib/src/verify/checks/docs_stale_check.dart`
- Modify: `packages/appstein_engine/lib/src/docs/docs_run.dart`, `docs_folder.dart`, `docs_renderer.dart`, `doc_marker.dart`; the feature pages' path code in `packs/official_mvvm/docs/feature_pages.dart`
- Test: `packages/appstein_engine/test/docs/docs_folder_test.dart`, `docs_renderer_test.dart`, `docs_run_test.dart` (add cases); `packages/appstein_engine/test/verify/checks/docs_stale_check_test.dart`

**Interfaces:**
- Consumes: `VerifyCheck`, `VerifyContext` (Task 3).
- Produces:

```dart
/// The pages a render gives now, compared with the docs folder.
sealed class DocsPrepared { const DocsPrepared(); }

/// The pages can't be rendered or compared.
final class DocsNotPrepared extends DocsPrepared {
  const DocsNotPrepared(this.problem, {this.fixHint, this.details = const []});
  final String problem;
  final String? fixHint;
  final List<String> details;
}

/// The rendered pages and what differs.
final class DocsPlan extends DocsPrepared {
  const DocsPlan({required this.folder, required this.pages, required this.scan, required this.changes, required this.blocked});
  final String folder;                 // absolute
  final List<RenderedPage> pages;
  final DocsFolderScan scan;
  final List<DocChange> changes;
  final List<String> blocked;
}

/// Reads [snapshot], renders every page and plans the docs folder. The
/// caller holds the knowledge lock. `appstein docs` and `docs.stale` both
/// use it, so they can't disagree (spec §9.2).
DocsPrepared prepareDocs({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSnapshot snapshot,
  required DecisionSet decisions,
});

/// `docs.stale` (spec §9.2): full mode, warning, needs the map.
final class DocsStaleCheck implements VerifyCheck { const DocsStaleCheck(); }
```

**Part A: four minors (each: failing test, then the fix).**

- [ ] **Step 1: Final newline (spec §6.9, Line endings).** In `docs_folder_test.dart`: a generated page saved without its final newline, and one with two extra blank lines at the end, are both `DocChangeKind.unchanged`; a page with a blank line removed in the middle is still `handEdited`. Run, see the first two fail (`handEdited`). Fix: `planDocs` compares `_trimEnd(plainLines(text))` with `_trimEnd(page.text)`, where `_trimEnd` removes trailing `\n`s; `_handEdited` hashes the body with the same trimming so a later real change is still classed correctly (`bodyHash(bodyOf(text))` must equal the marker's hash for a page that only lost its final newline: normalize the body's end to exactly one `\n` inside `bodyOf`). Run, pass.

- [ ] **Step 2: A person's `<page>.tmp`.** Test: with `routes.md.tmp` (any content) in the docs folder and `routes.md` to be written, `planDocs` reports `blocked` containing `` `routes.md.tmp` is in the way: Appstein writes `routes.md` through a file of that name. Move or delete it. `` and nothing is written by `runDocs` (the `.tmp` file's bytes are unchanged). A `.tmp` next to an **unchanged** page blocks nothing. Run, fail; fix in `planDocs` (check `FileSystemEntity.typeSync('<target>.tmp')` only for pages whose change is `write`); run, pass.

- [ ] **Step 3: A linked parent folder.** Test (skipped on Windows when links can't be created, as the existing link test is): `docs` is a link to another folder and `docs.path` is `docs/app`: `scanDocsFolder` gives the problem `` the docs folder is inside `docs`, which is a link, and Appstein does not write through links. Make it a folder, or change `docs.path`. `` Fix: `scanDocsFolder` takes the project root too (`scanDocsFolder(String folder, {String? projectRoot})`) and checks each ancestor between the project root and the folder with `typeSync(followLinks: false)`. Update the callers. Run, pass.

- [ ] **Step 4: Page paths that can't be files, and pages that collide.** Tests in `docs_renderer_test.dart` with `FakeDocPage`: (a) a page path `features/a:b.md` or `features/a\b.md` is rendered at `features/a_b.md` (each of `\ : * ? " < > |` and control characters becomes `_`); (b) two sources rendering `features/Home.md` and `features/home.md` (different pages) make `renderPages` throw a new `DocPagesCollide` exception whose message is `` Two pages would be the same file on Windows and macOS: `features/Home.md` and `features/home.md`. Rename one of the feature folders. `` Sections with the **same** path are still joined, as today. In `docs_run_test.dart`: with feature folders `lib/ui/Home` and `lib/ui/home` in the fixture copy, `runDocs` returns `DocsRefused` with that problem and writes nothing (exit 1, not a crash). Fix: sanitize in `renderPages`; detect collisions after joining; `prepareDocs` catches `DocPagesCollide`.

**Part B: `prepareDocs`.**

- [ ] **Step 5: Move the code.** Move the body of the locked block in `runDocs` (reading the seven snapshot files, the scan, `renderPages`, `planDocs`) into `prepareDocs`, returning `DocsNotPrepared` where `runDocs` returned `refused(...)`. `runDocs` keeps: disabled, refresh, lock, `prepareDocs`, the `blocked` refusal, `applyDocs`, `DocsDone`. Run the engine and CLI suites: all docs tests pass unchanged.

**Part C: `docs.stale`.**

- [ ] **Step 6: Write the failing tests.** `docs_stale_check_test.dart` builds a `VerifyContext` on the fixture after one real sync (helper `contextFor(app, {config})` in `verify_support.dart`: runs `knowledgeSync(...).run(app)`, then returns the context with `KnowledgeSnapshot(app)` and `readDecisions(app)`):
  - **passing fixture:** after `runDocs` wrote the pages, `run` gives no finding;
  - **never rendered:** 11 warnings, one per page, each `file: 'docs/app/<page>'`, message `The page is missing.`, fix hint ``Run `appstein docs`.``, `knowledgeRef: '.appstein/INDEX.md'`; nothing under `docs/app` exists afterwards;
  - **behind:** after rendering, add a route to the fixture and sync: `docs/app/routes.md` (and any other page the change reaches) gives `The page is behind the app.`;
  - **hand-edited:** `The page was edited by hand; `appstein docs` will overwrite the edit.` with fix hint ``Run `appstein docs`, and keep your own text in a file without the marker line.``;
  - **merge conflict:** `The page has a merge conflict.`;
  - **no longer rendered:** `The page is no longer rendered.`; **edited leftover:** `The page is no longer rendered, and was edited by hand.` with fix hint `Delete it, or remove its first line to keep it as a team note.`;
  - **a person's file in the way:** one finding per `blocked` sentence, on `file: 'docs/app'`, message the sentence, no page findings lost;
  - **the folder can't be read** (`docs/app` is a file): one finding on `docs/app` with the scan's problem;
  - **docs turned off:** `config.docs.enabled == false` gives no finding and reads no file under the docs folder;
  - **custom path:** `docs.path: handbook` gives `file: 'handbook/README.md'`;
  - `ids == ['docs.stale']`, `mode == VerifyMode.full`, `needsMap == true`.

- [ ] **Step 7: Run to see them fail.** `fvm dart test test/verify/checks/docs_stale_check_test.dart`. Expected: FAIL, no check.

- [ ] **Step 8: Write `DocsStaleCheck`.** It calls `prepareDocs` with the context's snapshot and decisions and maps `DocsNotPrepared`, `blocked` and each change whose kind isn't `unchanged` to findings as the tests say. Severity `Severity.warning`.

- [ ] **Step 9: Run** `fvm dart test` in the engine and the CLI. Expected: all pass. Update the docs goldens only if Step 4's sanitizing changed a golden page (it should not: the fixture has no such names).

- [ ] **Step 10: Commit** `feat: docs.stale, from the same code as docs --check; four docs folder fixes`

---

### Task 6: Renderer text minors

**Files:**
- Modify: `packages/appstein_engine/lib/src/docs/markdown_text.dart`, `docs_folder.dart` (team-note titles), `pages/decisions_page.dart`, `pages/readme_page.dart`, `native_section.dart`, `packs/official_mvvm/docs/routes_page.dart`, `feature_pages.dart`
- Test: `packages/appstein_engine/test/docs/markdown_text_test.dart`, `docs_folder_test.dart`, `pages/*_test.dart`, `packs/official_mvvm/docs/*_test.dart`, `packs/native_docs_test.dart`; goldens under `test/fixtures/apps/goldens/docs/`

Each item: failing test first, then the fix.

- [ ] **Step 1: `|` only escaped in tables.** `mdCode('/a|b')` gives `` `/a|b` ``; a new `mdCodeCell('/a|b')` gives `` `/a\|b` `` and `mdTable` uses it for cells. Update the call sites: list items use `mdCode`, table cells `mdCodeCell`.
- [ ] **Step 2: A route with an empty name.** In `routes_page_test.dart`: `_route('/a', 5, name: '', screen: 'A')` renders `` - `/a` shows `A` (…) `` with no `, named`.
- [ ] **Step 3: Headings.** A feature named `a*b_c` and a pubspec name `my_app` are escaped in the `# ` title (`mdText`), so `# a\*b\_c`. Test in `docs_renderer_test.dart` that `renderPages` escapes a `DocSection.title` (the frame does it once, so no page can forget), and adjust pages that pre-escaped.
- [ ] **Step 4: `&`, `~`, `$`, and `#` in Mermaid.** `mdText('a & b ~c~ $x$')` gives `a &amp; b \~c\~ \$x\$`; `mermaidLabel('C#')` gives `C#35;`.
- [ ] **Step 5: Team-note titles.** In `docs_folder_test.dart`: a note whose first `# ` line is inside a ``` or ~~~ fence, with a real `# Title` after the fence, is titled `Title`; a note with a heading only inside a fence is titled by its path.
- [ ] **Step 6: OS wording in `decisions.md`.** With an unreadable decision file, the page says `could not be read` and never contains the OS's message (test with two different `readProblems` texts giving byte-identical pages). `verify` (`decision.unreadable`, Task 7) and the `decisions` tool still show the OS's reason.
- [ ] **Step 7: A reason that names this machine's Flutter.** In `native_docs_test.dart`: two renders of the same project with two different unpinned Flutter versions in `sdk.json` give byte-identical `native.md`. Find where an unknown value's reason is rendered in `native_section.dart`; when `sdk.fvmVersion == null`, a reason that contains the SDK's version is shown with the version replaced by `the Flutter in use`.
- [ ] **Step 8: Run** `fvm dart test` in the engine. Read every golden that changed, as a person would, before accepting it. Expected: all pass.
- [ ] **Step 9: Bump the template versions.** Page shapes changed, so `docsEngineVersion` becomes `'2'` and `OfficialMvvmPack.version` becomes `'3'`; markers change, and `docs --check` reports old pages as behind, which is right. Update goldens and the tests that name the versions.
- [ ] **Step 10: Commit** `fix: the renderer's escaping, team-note titles and machine wording`

---

### Task 7: Decision checks

**Files:**
- Create: `packages/appstein_engine/lib/src/verify/decision_check.dart`, `packages/appstein_engine/lib/src/verify/checks/decisions_check.dart`, `packages/appstein_engine/lib/src/verify/checks/paths_exist_check.dart`, `packages/appstein_engine/lib/src/packs/official_mvvm/stack_provider_check.dart`
- Modify: `packages/appstein_engine/lib/src/packs/pack.dart`, `official_mvvm_pack.dart`, `android/android_pack.dart`, `ios/ios_pack.dart`, `lib/official_mvvm.dart`, `lib/appstein_engine.dart`; every test `Pack` implementation
- Test: `packages/appstein_engine/test/verify/checks/decisions_check_test.dart`, `paths_exist_check_test.dart`, `packages/appstein_engine/test/packs/official_mvvm/stack_provider_check_test.dart`, `packages/appstein_engine/test/packs/pack_checks_test.dart`

**Interfaces:**
- Consumes: `VerifyCheck`, `VerifyContext` (Task 3); `DecisionSet`, `DecisionEntry`, `decisionPath` (`decisions/decision_store.dart`).
- Produces:

```dart
/// A check a decision record can name in `checks:` (spec §6.7).
abstract interface class DecisionCheck {
  /// Its name in a decision file, such as `paths.exist`.
  String get id;
  /// Whether it reads the project map.
  bool get needsMap;
  /// What no longer holds for [decision], one sentence each; empty when it
  /// holds.
  List<String> problems(DecisionEntry decision, VerifyContext context);
}

// in Pack:
  /// The checks it adds to `verify` (spec §9).
  List<VerifyCheck> get checks;
  /// The checks a decision record can name (spec §6.7).
  List<DecisionCheck> get decisionChecks;

/// `paths.exist`, the engine's decision check.
final class PathsExistCheck implements DecisionCheck { const PathsExistCheck(); }

/// `decision.drift`, `decision.unreadable` and `decision.duplicate` (spec
/// §6.7): full mode, warnings.
final class DecisionsCheck implements VerifyCheck {
  const DecisionsCheck(this.decisionChecks);
  final List<DecisionCheck> decisionChecks;
}

/// `stack.provider` (official_mvvm).
final class StackProviderCheck implements DecisionCheck { const StackProviderCheck(); }
```

`DecisionsCheck.needsMap` is `false`: `decision.unreadable`, `decision.duplicate` and `paths.exist` don't read the map. A decision check with `needsMap` is run only when the seven map files of `context.knowledge` have no problem; otherwise that decision gets no finding from it (the run already carries `knowledge.stale`). Whether the map is ready is computed from `context.knowledge` inside the check.

**`DecisionsCheck.run`:**
- `folderProblem`: one `decision.unreadable` on `.appstein/decisions`: `The decisions folder could not be listed (<reason>).`
- each `unreadable` file: `decision.unreadable` on `decisionPath(file)`: `The decision can't be read: <reason>.` with fix hint `Fix its front matter (spec format: id, title, status, date, paths, checks), or delete the file.`
- each sentence in `problems` (a circle): `decision.unreadable` on `.appstein/decisions` with that sentence.
- each `duplicates` entry: one `decision.duplicate` per file: `Decision <NNNN> is also `<other file>`.` with fix hint `Rename one of them to the next free number, <next>.`
- for each entry with `status == accepted` (the reader's status), for each name in `record.checks`: no `DecisionCheck` with that id among `decisionChecks` gives `decision.drift`: ``The decision names the check `<name>`, which no pack of this project provides.``; otherwise each sentence from `problems(...)` gives one `decision.drift` with that sentence, fix hint `Bring the code back in line, or replace the decision with a new one (`record_decision` with `supersedes`).`, and `knowledgeRef` the decision's path.
- `line`: the 1-based line of the `checks:` key in the file (`paths:` for `paths.exist`), found in `context.decisions.bytes[file]` decoded with `allowMalformed`, after removing a BOM, splitting on `\n` and trimming `\r`: the first line inside the front matter that starts with the key and `:`. Null when not found.
- proposed and superseded decisions are never checked.

**`PathsExistCheck.problems`:** for each pattern in `record.paths`:
- a pattern that could leave the project is reported and not expanded: after replacing `\` with `/`, it is absolute, or any `/`-segment, **or any alternative inside braces**, is `..` (regex ``(^|[/{,])\.\.([/},]|$)``): ``The path `<pattern>` could leave the project, so it was not checked.``
- otherwise list files with `Glob(pattern, context: p.posix).listSync(root: projectRoot, followLinks: false)`; a pattern with no glob character is checked with `FileSystemEntity.typeSync` (a file or a folder counts). No match: ``The path `<pattern>` matches no file.``
- a pattern the glob package refuses: ``The path `<pattern>` is not a valid pattern.``
- a decision with no `paths` holds.

**`StackProviderCheck`** (`needsMap: true`): reads `context.knowledge.deps.value!`.
- `provider` missing, or its `dependency` isn't `direct main`: ``The project does not depend on `provider`.``
- for each package in the pack's list that has at least one usage under `lib/`: ``<n> file(s) under lib/ import `<package>`: <first three files>[, and <k> more].``
- the list, in the pack: `riverpod`, `flutter_riverpod`, `hooks_riverpod`, `bloc`, `flutter_bloc`, `hydrated_bloc`, `get`, `mobx`, `flutter_mobx`, `redux`, `flutter_redux`, `signals`, `signals_flutter`, `stacked`.

- [ ] **Step 1: Write the failing tests**

`paths_exist_check_test.dart` (a temp project; `decisionEntry(...)` from `test/docs/support/docs_support.dart`, moved to `test/support/` if both need it):
- `lib/ui/**/view_models/**` matching a file: no problem; a plain file path that exists; a plain folder that exists;
- a file path that doesn't exist; a glob matching nothing: the sentence, per pattern;
- `{..,lib}/x`, `../x`, `lib/../../x`, `/etc/passwd`, `C:\x`: "could leave the project", and a marker file outside the project is never listed (assert by putting a matching file in the parent folder);
- `lib/[x`: "is not a valid pattern";
- no paths: empty.

`stack_provider_check_test.dart` (a `VerifyContext` over a temp `.appstein/map/deps.json` written from a `DepsMap`):
- provider direct main, no other package: empty;
- provider missing; provider only `transitive`; provider `direct dev`: the "does not depend" sentence;
- `flutter_riverpod` used by two `lib/` files: one sentence naming both; five files: three named, `and 2 more`;
- `flutter_bloc` in `pubspec.lock` with no usages, or used only under `test/`: empty.

`decisions_check_test.dart` (decision files written with the helpers in `test/decisions/support/decision_files.dart`):
- **passing fixture:** an accepted decision with `checks: [paths.exist]` whose paths exist: no finding;
- **failing:** a path that matches nothing: one `decision.drift` warning on `.appstein/decisions/0001-….md`, at the line of `paths:`, with the sentence;
- the same decision `proposed`, or superseded by another file's `supersedes` while its own status line says `accepted`: no finding;
- an accepted decision naming `stack.provider` with no pack providing it: the "no pack of this project provides" finding at the line of `checks:`;
- with `StackProviderCheck` given and a bad `deps.json`: its sentences; with `deps.json` missing: no `decision.drift` from it;
- **Review Focus 2:** the same failing file saved with CRLF line endings and a BOM gives the same line number;
- an unreadable file: `decision.unreadable` with its reason; two files numbered 0003: two `decision.duplicate` findings, each naming the other; a circle (1 supersedes 2, 2 supersedes 1): `decision.unreadable` with the reader's sentence;
- `ids`, `mode == full`, `needsMap == false`.

`pack_checks_test.dart`: `OfficialMvvmPack().decisionChecks.map((c) => c.id)` is `['stack.provider']`; Android and iOS give none; **every name in `decisionChecks` (the protocol constant) is provided by the engine or a built-in pack** (`paths.exist` by the engine, `stack.provider` by official_mvvm), so `record_decision` never accepts a name `verify` can't run.

- [ ] **Step 2: Run to see them fail.** `fvm dart test test/verify/checks test/packs`. Expected: FAIL to compile.

- [ ] **Step 3: Write the code.** Add the two members to `Pack` and to every implementation (`const []` for Android and iOS and for the test packs); write the three checks.

- [ ] **Step 4: Run** `fvm dart test` in the engine and the CLI. Expected: all pass.

- [ ] **Step 5: Commit** `feat: decision checks: paths.exist, stack.provider, decision.drift`

---

### Task 8: `memory.lessons_long`, `verify.test_required`, and the engine's check list

**Files:**
- Create: `packages/appstein_engine/lib/src/verify/checks/lessons_long_check.dart`, `test_required_check.dart`, `packages/appstein_engine/lib/src/verify/engine_checks.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/verify/checks/lessons_long_check_test.dart`, `test_required_check_test.dart`, `packages/appstein_engine/test/verify/verify_fixture_test.dart`

**Interfaces:**
- Produces:

```dart
/// `memory.lessons_long` (spec §6.8): full mode, info, no map.
final class LessonsLongCheck implements VerifyCheck { const LessonsLongCheck({this.limit = 200}); final int limit; }

/// `verify.test_required` (spec §9.2): full mode, warning, needs the map.
final class TestRequiredCheck implements VerifyCheck { const TestRequiredCheck(); }

/// The decision checks the engine provides.
const engineDecisionChecks = <DecisionCheck>[PathsExistCheck()];

/// Every check of a project with [packs]: the engine's, then each pack's,
/// each with the pack that contributed it.
List<({VerifyCheck check, String? pack})> checksFor(List<Pack> packs);
```

`checksFor` returns, in order: `DocsStaleCheck`, `DecisionsCheck([...engineDecisionChecks, for each pack ...pack.decisionChecks])`, `LessonsLongCheck`, `TestRequiredCheck` (all with `pack: null`), then each pack's `checks` with `pack: pack.id`. It throws a `StateError` when two checks declare the same ID (a bug in a pack), naming the ID and both sources.

- **`LessonsLongCheck`:** reads `.appstein/memory/lessons.md` with `readMemoryFile`/`memoryText` (`lib/src/memory/memory_store.dart`); counts lines as `LineSplitter` does. More than `limit`: one info finding on `.appstein/memory/lessons.md`: `lessons.md has <n> lines; over <limit>, it is slow to read in full.`, fix hint `Merge related lessons into fewer lines. Nothing is deleted automatically.` Missing or unreadable file: no finding.
- **`TestRequiredCheck`:** for each feature in `context.knowledge.features.value!` with `tests` empty: one warning on `feature.folder`: ``The feature `<name>` has no test.``, fix hint ``Add a test under `test/ui/<name>/`.``, `knowledgeRef: '.appstein/map/features.json'`. Sorted by feature name.

  The fix hint's `test/ui/` is where the map looks; it comes from `Feature`'s contract, not from stack knowledge added here. Read `packs/official_mvvm/features.dart` first: if the folder is the pack's choice, take the hint's folder from the feature's `folder` (`lib/ui/x` to `test/ui/x`) instead of a constant.

- [ ] **Step 1: Write the failing tests**

`lessons_long_check_test.dart`: no file; 200 lines: nothing; 201 lines: the info finding with `201`; a `limit: 3` check with 4 lines.

`test_required_check_test.dart` on the synced fixture: findings exactly for `auth/login`, `profile` and `settings` (the fixture has tests for `booking` and `home` only), each on its folder; after adding `test/ui/profile/profile_test.dart` and syncing, `profile` is gone.

`verify_fixture_test.dart`, the whole thing on the fixture with `checksFor(_packs)` and the real `runVerify`:
- **full, after `runDocs`:** exactly three findings, the `verify.test_required` warnings; `errors == 0`; `notRun` empty; `suppressed == 0`.
- **full, docs never rendered:** those three plus 11 `docs.stale`.
- **fast:** no finding (no fast check reports on a healthy project); `DocsStaleCheck` was not run (the docs folder still doesn't exist and no time is spent rendering: assert by a `docs.path` that is a file, which full mode reports and fast mode doesn't).
- **with a broken Flutter root, full:** `knowledge.stale` (error) and `notRun` is exactly `docs.stale` and `verify.test_required`; `decision.*` and `memory.lessons_long` ran.
- `checksFor` with two packs declaring the same ID throws the `StateError`.

- [ ] **Step 2: Run to see them fail.** `fvm dart test test/verify`. Expected: FAIL to compile.
- [ ] **Step 3: Write the two checks and `engine_checks.dart`; export.**
- [ ] **Step 4: Run** `fvm dart test` in the engine. Expected: all pass.
- [ ] **Step 5: Commit** `feat: memory.lessons_long, verify.test_required and the engine's check list`

---

### Task 9: `appstein verify`

**Files:**
- Create: `packages/appstein_cli/lib/src/verify_command.dart`
- Modify: `packages/appstein_cli/lib/src/runner.dart`, `packages/appstein_cli/lib/appstein_cli.dart`, `test/generators_test.dart`
- Test: `packages/appstein_cli/test/verify_command_test.dart`

**Interfaces:**
- Consumes: `runVerify`, `checksFor`, `VerifyCheckError`, `VerifyMode` (engine); `VerifyResult` (protocol).
- Produces:

```dart
final class VerifyCommand extends Command<int> {
  VerifyCommand({required this.out, required this.err, required this.environment});
}
/// The text `appstein verify` prints (spec §9.3).
String formatVerify(VerifyResult result);
/// 1 when the result has an error, else 0 (spec §9.5).
int verifyExitCode(VerifyResult result);
```

Flags: `--fast` and `--full` (both `negatable: false`; both given is a `UsageException`: `Pass --fast or --full, not both.`), `--format` with `allowed: ['text', 'json']`, default `text`. Description: `Check the project against its knowledge (fast or full).`

`run()`: resolve the project as `DocsCommand` does (same two-line message, with `appstein verify`); load the config (a `ConfigException` gives the error and ``Fix appstein.yaml, then run `appstein verify` again.``, exit 3); `packs = packsFor(config)`; `runVerify(...)` with a `KnowledgeSync` built as `DocsCommand` builds it (`packageSkills: false`); `VerifyCheckError` is not caught, so `runAppstein`'s crash handler reports it and returns 3 (add a `VerifyCheckError` case there that prints `The check `<id>` failed: …` before the usual crash text). JSON output is `const JsonEncoder.withIndent('  ').convert(result.toJson())` plus a newline. Both formats go to `out`.

**Text format**, exactly:

```
(project)
  error knowledge.stale: The knowledge could not be brought up to date: …
    fix: Run `flutter pub get` in the project to see the whole error. Then run `appstein verify` again.

.appstein/decisions/0002-state.md
  warning decision.drift (line 7): 2 files under lib/ import `flutter_riverpod`: lib/a.dart, lib/b.dart.
    fix: Bring the code back in line, or replace the decision with a new one (`record_decision` with `supersedes`).

lib/ui/profile
  warning verify.test_required: The feature `profile` has no test.
    fix: Add a test under `test/ui/profile/`.

Not run:
  docs.stale: the project map is not up to date
  verify.test_required: the project map is not up to date

1 error, 2 warnings, 0 info. 1 suppression active.
```

- Groups: `(project)` for findings without a file, then each file. **A group with an error comes before a group without one**; inside that, `(project)` first, then by path. Inside a group, `sortFindings` order.
- A `fix:` line only when there is a fix hint. A blank line after each group and after the `Not run:` block; that block only when something wasn't run.
- Summary: `1 error` / `2 errors`, `1 warning` / `n warnings`, `n info`; then `No suppressions active.`, `1 suppression active.` or `n suppressions active.`
- With no finding and nothing not run, the output is the summary line alone.

- [ ] **Step 1: Write the failing tests**

`verify_command_test.dart`:
- `formatVerify`: the example above, byte for byte, from a hand-built `VerifyResult`; the empty result gives `0 errors, 0 warnings, 0 info. No suppressions active.\n`; singular and plural forms; a warning-only file sorts after an error file even when its path sorts first.
- `verifyExitCode`: 0 for no finding, for warnings only, for info only; 1 for one error.
- through `runAppstein` on a copy of the fixture with the fake Flutter SDK (as `docs_command_test.dart` does):
  - `verify` on the fixture exits 0 and prints the three `verify.test_required` groups and 11 `docs.stale` groups; `verify --fast` exits 0 and prints the summary line alone;
  - `verify --format json` prints JSON that `VerifyResult.fromJson` reads, with the same findings;
  - a `suppressions:` entry without a reason: exit 1, `suppression.no_reason` on `appstein.yaml (line N)`;
  - an accepted decision whose path doesn't exist: exit 0 (a warning), the `decision.drift` group; with `verify: {severity: {decision.drift: error}}`: exit 1;
  - **Review Focus 5:** no `appstein.yaml` and no `.appstein/`: exit 0, the knowledge is built (`.appstein/INDEX.md` exists afterwards) and the findings are printed;
  - no project: exit 3, the message names `appstein verify`; a bad `appstein.yaml`: exit 3;
  - `--fast --full`: exit 3, `Pass --fast or --full, not both.`;
  - `--format xml`: exit 3;
  - a check that throws (pass an `extraCommands` test command, or a `VerifyCommand` with an injected `checks` override for tests): exit 3 and stderr names the check.
- `help verify` prints the description and the three flags.

Update `test/generators_test.dart`: `contains('\$ appstein help verify\nCheck the project against its knowledge')` and the fence count `12`, with the comment naming five commands.

- [ ] **Step 2: Run to see them fail.** `fvm dart test test/verify_command_test.dart` in `packages/appstein_cli`. Expected: FAIL to compile.
- [ ] **Step 3: Write `verify_command.dart`; register it in `runner.dart` after `DocsCommand`; export.**
- [ ] **Step 4: Run** `fvm dart test` in the CLI, `fvm dart run tool/gen_docs.dart` at the root (the CLI help section changes), then `fvm dart test test` at the root. Expected: all pass.
- [ ] **Step 5: Run it for real and read the output.** Build nothing: `fvm dart run packages/appstein_cli/bin/appstein.dart verify --project <a copy of the fixture with a pubspec.yaml>` in both formats and both modes. Read each line as a person who has never seen Appstein: is every message true, and does every fix hint work? Fix what isn't, test first.
- [ ] **Step 6: Commit** `feat: appstein verify, in text and JSON`

---

### Task 10: The `verify` MCP tool

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/verify_tool.dart`
- Modify: `packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart`, `tool_names.dart`, `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`, `packages/appstein_cli/lib/src/mcp_command.dart`, `packages/appstein_engine/lib/src/index/index_document.dart` (only if a fallback for `verify` remains)
- Test: `packages/appstein_engine/test/mcp/verify_tool_test.dart`, `appstein_mcp_server_test.dart`, `mcp_stdio_test.dart`, `packages/appstein_cli/test/mcp_command_test.dart`, the INDEX goldens

**Interfaces:**
- Consumes: `runVerify`, `checksFor`, `KnowledgeRefresh.fromFreshness`.
- Produces:

```dart
// tool_schemas.dart
static final Map<String, Object?> verifyInput;   // {scope: 'fast' | 'full'}, required
static final Map<String, Object?> verifyResult;  // findings, summary{errors,warnings,info}, suppressed, notRun

// verify_tool.dart
/// The `verify` tool (spec §8): `verify`'s result as `--format json` prints
/// it, with a one-sentence summary.
ToolAnswer verifyAnswer(VerifyResult result, {required VerifyMode mode});
```

`AppsteinMcpServer` gains `required this.configFor` (`AppsteinConfig Function()`), called once per `verify` call; the CLI passes `() => loadConfig(projectRoot) ?? const AppsteinConfig()`. The tool is registered with a new private `_asyncTool` whose handler gets the freshness and returns a `Future<ToolAnswer>`:

```dart
final freshness = await _freshen();
final sync = syncFor();            // a ConfigException here is a refusal: 'appstein.yaml is invalid: …'
final config = configFor();
final result = await runVerify(
  projectRoot: projectRoot, config: config, packs: sync.packs, sync: sync,
  mode: scope == 'fast' ? VerifyMode.fast : VerifyMode.full,
  checks: checksFor(sync.packs),
  refreshed: KnowledgeRefresh.fromFreshness(freshness),
  dartSdkPath: dartSdkPath,
);
return verifyAnswer(result, mode: mode);
```

A thrown `VerifyCheckError` becomes the usual refusal (`Appstein failed to answer: …`). The summary sentence: `Full verify: 1 error, 2 warnings, 0 info.` plus, when it applies, ` 2 checks did not run.` and ` 1 finding is suppressed.`; with an error: ` Fix the errors before the task is done.` Tool description: `Check the project against its knowledge and get findings, each with its file, line and a fix hint. `scope: fast` after a change; `scope: full` before you say the task is done. An error blocks "done"; warnings and info are reported only.`

- [ ] **Step 1: Write the failing tests**
  - `verify_tool_test.dart`: `verifyAnswer` gives `result.toJson()` and each summary form.
  - `appstein_mcp_server_test.dart` (in-process client, as the other tools): `tools/list` includes `verify` with the input schema; `scope: full` on the fixture returns the three `verify.test_required` and 11 `docs.stale` findings in `structuredContent`, with `summary` and `freshness`; `scope: fast` returns none; a missing or wrong `scope` is refused by the schema before the tool runs; with a broken Flutter root, the reply is **not** an error: it has `knowledge.stale`, `notRun`, and `freshness.state == 'stale'`, and the fake runner shows the sync ran once, not twice; an invalid `appstein.yaml` gives an error reply naming it.
  - `mcp_stdio_test.dart`: one `verify` call over real stdio returns `summary`.
  - `mcp_command_test.dart`: the command builds the server with `configFor`.
  - INDEX: with `verify` served, `INDEX.md` has the rule that names `verify`; update the INDEX goldens and the test that pins `mcpToolNames`.
- [ ] **Step 2: Run to see them fail.** `fvm dart test test/mcp` in the engine. Expected: FAIL.
- [ ] **Step 3: Write the schemas, `verify_tool.dart`, `_asyncTool`, the registration; add `'verify'` to `mcpToolNames` (after `memory_write`) and fix its doc comment; remove any `verify` fallback text in `index_document.dart` that can no longer be reached, keeping `package_check`'s.**
- [ ] **Step 4: Run** `fvm dart test` in the engine, the CLI and the root. Read the changed INDEX golden as a person. Expected: all pass.
- [ ] **Step 5: Commit** `feat: the verify MCP tool`

---

### Task 11: Measure the real binary

**Files:**
- Modify: `tool/measure_sync.dart`, `docs/guide/ci.md` (the numbers' description), `.github/workflows/ci.yml` only if the step's name lists what it measures

- [ ] **Step 1: Read `tool/measure_sync.dart`'s docs rows (lines 205–320) and add verify rows the same way**, on the 200-file app, after the docs rows (so the pages exist):
  - `verifyFast`: `appstein verify --fast`, median of 3, exit 0, output ends with the summary line; **asserted under 5 s** (spec §9.1).
  - `verifyFull`: `appstein verify`, median of 3, exit 0; recorded, with no limit (the spec sets none).
  - one correctness run: after the existing hand edit of `routes.md`, `appstein verify --format json` exits 0 and its JSON has exactly one `docs.stale` finding on `docs/app/routes.md`.
  Add the two rows to the printed table and to the file's header comment.
- [ ] **Step 2: Run it locally:** `fvm dart run tool/measure_sync.dart` (as the guide's `ci.md` says). Expected: the new rows print; fast is under 5 s. Record the numbers for the plan's notes.
- [ ] **Step 3: Run** `fvm dart test test` at the root (the tool has tests there). Expected: pass.
- [ ] **Step 4: Commit** `test: measure appstein verify with the real binary`

---

### Task 12: Docs, graph and progress

**Files:**
- Create: `docs/guide/verify.md`, `docs/guide/how-to/add-a-check.md`
- Modify: `docs/guide/cli.md`, `mcp-server.md`, `architecture.md`, `human-docs.md`, `README.md`, `ci.md`, the page that covers `packs/pack.dart` and `config_loader.dart`; `docs/superpowers/progress.yaml`; this plan (notes from execution)

- [ ] **Step 1: Write `verify.md`** (covers `lib/src/verify/**`, `verify_command.dart`, `mcp/verify_tool.dart`, `protocol/lib/src/verify/**`, `knowledge/knowledge_refresh.dart`): what verify is for; the run in five steps; the table of checks in this slice with ID, source, mode, severity; findings and the two output formats with the real example; suppressions and what can't be suppressed; exit codes; what later slices add. Write `add-a-check.md`: the `VerifyCheck` contract, where an engine check and a pack check go, the passing-and-failing-fixture rule, registering IDs, a decision check.
- [ ] **Step 2: Update the other pages** for `Pack.checks`/`decisionChecks`, `suppressions:` and the `docs.path` rule, `prepareDocs`, the tool list, the measured rows.
- [ ] **Step 3:** `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`. Expected: nothing reported. `fvm dart doc --dry-run` in each of the four packages: no warning.
- [ ] **Step 4: Whole-repo check:** `fvm dart analyze` at the root (no issue), `fvm dart format --output=none --set-exit-if-changed .` (no change), all five suites, the BOM gate.
- [ ] **Step 5: Final review** by one fresh reviewer on the most capable model, with this plan's Review Focus; fix Critical and Important findings test-first; record minors.
- [ ] **Step 6: Commit the docs**; then `/graphify . --update` by the runbook until `tool/check_graph.py` reports nothing.
- [ ] **Step 7: After the PR is open:** mark 1d.1 done in `progress.yaml` with `plan`, `pr` and `finished`, mark 1d.2 `next`, add the notes from execution to this plan, `gen_docs`, read back the page, commit.

---

## Carried to later slices

- **1d.2:** `--files`, `--hook`, exit code 2, the Dart `// appstein:ignore` comments; analyze, fix, format and test checks; warm analysis and the 5 s proof with real checks; a `verify.severity` key that names no check (decide once lint rule IDs are verify IDs).
- **1d.3:** the lint rules; the stack knowledge in `feature_query.dart`, `route_query.dart` and `index/` moves into the pack.
- **1d.4:** the package gate; the verdict column in `dependencies.md`.
- **1d.5, 1d.6:** Android and iOS checks; `toolchain_report.dart`'s knowledge moves into the packs; the plugin behind each permission in `native.md`.

From the final review, not fixed in this slice:

- **1d.2:** a glob escape in a decision's path (`\[`) is broken, because `paths.exist` turns every `\` into `/` first. Solved by keeping a `\` that escapes a glob character; checked by a test with a file named `a[1].dart`.
- **1d.2:** the CLI's own tests can't run `verify` on a healthy project (their fake Flutter SDK has no Dart SDK), so exit 0 is proven in the engine's `verify_fixture_test.dart` and by `tool/measure_sync.dart` with the real binary. 1d.2's fast checks need a real analysis in the CLI tests anyway; give `runAppstein` the Dart SDK path the engine tests use, then add the healthy-project run there.
- **1d.2:** a suppression `path` of the form `C:foo` (drive-relative) is accepted as a relative path and can only ever be unused. Refuse it in the loader with the other absolute forms.

---

## Notes from execution

Executed natively in one session (owner's choice), with one independent review of the whole branch at the end.

**Results**

- Suites at the end: protocol 78, engine 1,308, CLI 100, root 225. Analyzer, format, guide check, `dart doc --dry-run` in all four packages and the BOM scan are clean.
- Measured with the compiled binary on the 200-file app (Windows development machine): `verify --fast` 129 ms as the median of three (target under 5 s), full `verify` 176 ms. `verify --format json` reported the page edited by hand as the one `docs.stale` finding.
- The real command was run on a copy of the fixture app with real packages, in both modes and both formats, with a decision and suppressions added, and every line of output was read.

**Rulings made during execution**

1. **Task 5:** a `<page>.tmp` is in the way unless a write of a page could have left it. The first rule ("empty, or starts like a page") was tightened after the review: only an empty file, a whole page nobody edited, or the start of the page being written counts as a leftover.
2. **Task 5:** the feature pages find two feature names that give one file name themselves and throw `DocPagesCollide` naming both; `renderPages` passes it through and still joins sections that share a path on purpose (`native.md`). `docFileName` also handles a trailing dot or space and Windows device names.
3. **Task 6:** pipes are escaped in `mdTable`, not in a second "code for a table cell" function. `NativeValue.unknown` gained `resolvedFrom`, so an iOS value that is unknown because of one machine is hidden by the existing source rules. `decisions.md` no longer shows the operating system's message for a file it couldn't open.
4. **Task 7:** `KnowledgeSnapshot.mapProblem` is the one "can the map be used" test for `runVerify` and `prepareDocs`. An unknown decision check has its own fix hint.
5. **Task 8:** the fix hint of `verify.test_required` takes the test folder from the feature's folder (`lib/x` to `test/x`), not from a constant.
6. **Task 9:** the CLI's in-process tests cover runs where the map can't be built (see Carried). A `verifyChecks` parameter on `runAppstein` replaces the checks in tests, as `doctorChecks` does.
7. **Task 10:** no `configFor` parameter: the server reads `appstein.yaml` itself. The freshness step hands the sync it built to `verify`, so the sync is built once. `verify`'s structured `summary` is the counts (spec §9.3), so its sentence is in the reply's text only, and `toolOutputSchema` keeps a result's own `summary`.
8. **Summary line (owner: "choose the best for the project"):** the spec asked for "the number of active suppressions", the result counted hidden findings. Both are now given (`3 findings suppressed by 1 suppression.`), the result has `activeSuppressions`, and spec §9.3 and §9.7 say so.
9. **`paths.exist` accepts a folder** for a plain path, as the plan says; the spec's words are "matches at least one file". Letter case counts on every system, and `.dart_tool`, `.git` and `build` are not searched unless the pattern names them. These three are not in the spec text yet.

**The final review** found no Critical problem, four Important ones and several smaller ones. All four Important ones were fixed test first:

- `.appstein` that can't be opened crashed `verify`; it is now `knowledge.stale`.
- A decision check that reads the map judged old map files after a failed refresh. `VerifyContext.mapProblem` is now set whenever the refresh failed, and a part a check leaves out is named as not run (`context.skipped`).
- A suppression of a check that did not run was reported as unused, with advice to delete it.
- `stack.provider` reported a `provider` that pub calls `direct overridden` as missing.

The owner chose to fix four smaller ones too: the `docs.path` rule ignoring letter case, the `paths.exist` hardening, the busy lock waited for twice with no fix hint, and the edited copy saved as `<page>.tmp`. The rest are under Carried.

**Where the process slipped**

- For Task 2 and the first half of Task 4, the tests were written first but only seen failing to compile. From Task 7 on, each check was first written with an empty body so the tests failed on behaviour.
- The Task 9 command and the `docs.path` case fix were written straight after their tests, without watching the tests fail.
- A scratch script to edit a source file was written and never run; the Edit tool was used instead.
- The Task 7 commit message had a malformed `Docs-Checked` line, which failed the guide check. With the owner's permission the message was reworded on the unpushed branch; the files were byte-identical before and after.
- The plan's CLI tests assumed a healthy project could be verified in the CLI's own tests. It can't (see Carried), which a look at `docs_command_test.dart` while planning would have shown.
