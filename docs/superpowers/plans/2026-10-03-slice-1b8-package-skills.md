# Slice 1b.8: Package Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync` runs package:skills when the project's dependencies change, for the agents already set up in the project, and turns every failure into a one-line warning.

**Architecture:** A new engine file, `packages/appstein_engine/lib/src/skills/package_skills.dart`, holds everything about package skills: which agents are set up, the record in `.dart_tool/appstein/package_skills.json`, judging a run from its output, and `PackageSkills.refresh`, which decides whether to run, takes a lock and runs `dart run skills@1.0.3`. `KnowledgeSync` calls it after the knowledge is written (in `run` and in both branches of `detect`) and puts the result in `SyncReport.packageSkills`. The CLI passes `integrations.agents` from `appstein.yaml` and prints at most one line.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 via FVM), `package:test`, the engine's `ProcessRunner`, `KnowledgeLock` and `replaceFile`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §6.6 (as edited in `a6b4eb2`), with §6.2 (the record lives in `.dart_tool/appstein/`) and §15 (the sync targets leave out a package skills run).

## Global Constraints

- Every Dart command goes through FVM: `fvm dart …`, `fvm flutter …`. Run each package's suite from inside its folder (`cd packages/appstein_engine && fvm dart test`), never `fvm dart test packages/x` from the root.
- The pinned version is exactly `1.0.3`: `dart run skills@1.0.3`. Never `skills@^1` or an unpinned `skills@`.
- The command is `<flutterRoot>/bin/dart` (`dart.bat` on Windows) `run skills@1.0.3 -C <projectRoot> get --all --agent <agent>…`, started in `<projectRoot>`. Never the `dart` on PATH.
- Agents: `claude` when `<project>/.claude/` is a folder; `codex` when `<project>/.agents/` is a folder or `<project>/AGENTS.md` is a file. Only agents listed in `integrations.agents`. `sync` never creates an agent folder.
- The time limit is 120 s (`packageSkillsTimeout`).
- A package skills failure never fails `sync` and never changes the knowledge in `.appstein/`.
- A full sync (`KnowledgeSync.run`) retries a failed run for the same inputs; `detect` doesn't.
- Every public API gets a `///` comment (`public_member_api_docs` is on).
- Windows is first-class: test paths contain a space and a non-ASCII letter (`tempDir()` from `test/support/temp.dart`).
- Before every commit, the BOM gate must print nothing: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test`.
- Commit trailers: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW`. Code commits also carry `Docs-Checked: <page>.md - <reason>` for each guide page that covers a changed file and is still right, until Task 6 updates the pages.
- Never put a "Notes from execution" heading in this plan until the slice is finished: the guide check reads it as "slice done".

## Facts this plan relies on (verified 2026-10-03)

Read from the package:skills 1.0.3 source (dart-lang/ai, `pkgs/skills`) and a real run of `skills@1.0.3` on Windows (Flutter 3.47.5's `dart.bat`, stdin not a terminal):

- The success line, once per agent: `Installed 1 skill(s) for claude at .claude/skills.` and `Installed 0 skill(s) for generic at .agents/skills.` **Corrected after the final review:** when no dependency ships skills, it prints only `No skills found.` and exits 0, before installing (`get_skills.dart:184-190`); the `Installed 0` lines appear only when it pruned a removed package's skills. Codex is printed as `generic` (`--agent codex` is an alias of `generic`, `agent.dart:31`). Each installed skill also prints a line like `  [claude] Installed skill-pkg-demo`.
- `--agent nosuch` prints `"nosuch" is not an allowed value for option "--agent".`, then the usage text, and **exits 0**.
- `get` without `--all` prints `Rerun with \`--skill <name>\`, or \`--all\` …`, installs nothing, and exits 0.
- With no `.dart_tool/package_config.json`, it runs `dart.exe pub get` with the **PATH** Dart (3.4.1 on the owner's machine), which fails; it prints `Failed to run pub get.` and the usage text, and **exits 0**.
- With pub.dev unreachable, `dart run skills@1.0.3` exits 255 after about 41 s, printing `Got socket error trying to find package skills at …` on stderr.
- A first run took about 8 s (download and compile); later runs about 2.6 s.
- A package whose dependency was removed: its skills are deleted and the run prints `Installed 0 skill(s) for …`.
- Each run rewrites `%APPDATA%\dart_skills\global_config.json` (`{"gitRepos": []}`); the spec documents this (§6.6).
- `-C "<path with a space and ö>"` worked from Git Bash. Task 5's integration test checks the same through Dart's `Process.start`.
- Packages ship skills as `skills/<name>/SKILL.md` with front matter holding `name` and `description`; the convention is `<package-name-with-dashes>-<skill>`.

## Review Focus

1. **A run that exits 0 but failed** (unknown agent, a failed internal `pub get`, a usage error): it must be a warning, never "refreshed". Task 1 tests each real output.
2. **Two syncs at once** (the SessionStart hook and an after-edit hook): only one runs package:skills; the other prints nothing and doesn't wait. Task 2 holds the lock in the test and checks that no process starts.
3. **Offline:** a failed run must not run again on every `sync --detect` (each try costs about 41 s), but a full `sync` tries again. Task 2 and Task 3 test both.
4. **A project with no agent set up:** no process runs, no agent folder is created, and the one-line notice appears once, not on every sync. Task 2 and Task 3 test it.
5. **A damaged or foreign record file** (invalid JSON, wrong types, a folder in its place): it is treated as missing, and the run happens. Task 1 tests the reader; Task 2 tests that a record that can't be written becomes a warning.

---

### Task 1: Agents, the record and judging a run

**Files:**
- Create: `packages/appstein_engine/lib/src/skills/package_skills.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (add the export, in alphabetical order after the `src/sdk/…` exports and before the next group; keep the file's ordering)
- Test: `packages/appstein_engine/test/skills/package_skills_test.dart`

**Interfaces:**
- Consumes: `RunResult` (`lib/src/host/process_runner.dart`), `canonicalJson` (`lib/src/knowledge/canonical_json.dart`).
- Produces (later tasks rely on these exact names):
  - `const String packageSkillsVersion = '1.0.3';`
  - `const Duration packageSkillsTimeout = Duration(seconds: 120);`
  - `String packageSkillsRecordPath(String projectRoot)`
  - `List<String> setUpAgents(String projectRoot, List<String> configured)`
  - `final class PackageSkillsRecord` with `const PackageSkillsRecord({required String? pubspec, required String? lock, required List<String> agents, required String version, required bool succeeded})`, fields of the same names, `static PackageSkillsRecord? read(String projectRoot)`, `bool sameInputs(PackageSkillsRecord other)`, `PackageSkillsRecord withSucceeded(bool succeeded)`, `Map<String, Object?> toJson()`.
  - `String? packageSkillsFailure(RunResult result, List<String> agents)`

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/skills/package_skills_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

/// Real package:skills 1.0.3 output, captured on Windows (see the plan).
const _installedBoth =
    '  [claude] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for claude at .claude/skills.\n'
    '  [generic] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for generic at .agents/skills.\n';

const _nothingShipped =
    'Installed 0 skill(s) for claude at .claude/skills.\n'
    'Installed 0 skill(s) for generic at .agents/skills.\n';

const _badAgent =
    '"nosuch" is not an allowed value for option "--agent".\n'
    '\n'
    'Usage: skills get [arguments]\n'
    '-h, --help       Print this usage information.\n';

const _pubGetFailed =
    'Running dart.exe pub get...\n'
    'dart.exe pub get failed:\n'
    'The current Dart SDK version is 3.4.1.\n'
    '\n'
    'Failed to run pub get.\n'
    '\n'
    'Install skills from package dependencies.\n'
    '\n'
    'Usage: skills get [arguments]\n';

void main() {
  group('setUpAgents', () {
    late String project;

    setUp(() => project = tempDir().path);

    test('no agent folder means no agent', () {
      expect(setUpAgents(project, ['claude', 'codex']), isEmpty);
    });

    test('claude needs .claude/', () {
      Directory(p.join(project, '.claude')).createSync();
      expect(setUpAgents(project, ['claude', 'codex']), ['claude']);
    });

    test('codex needs .agents/ or AGENTS.md', () {
      Directory(p.join(project, '.agents')).createSync();
      expect(setUpAgents(project, ['claude', 'codex']), ['codex']);
      final other = tempDir().path;
      File(p.join(other, 'AGENTS.md')).writeAsStringSync('# Agents\n');
      expect(setUpAgents(other, ['claude', 'codex']), ['codex']);
    });

    test('a file named .claude or .agents does not count', () {
      File(p.join(project, '.claude')).writeAsStringSync('');
      File(p.join(project, '.agents')).writeAsStringSync('');
      expect(setUpAgents(project, ['claude', 'codex']), isEmpty);
    });

    test('only configured agents, in the configured order, once each', () {
      Directory(p.join(project, '.claude')).createSync();
      Directory(p.join(project, '.agents')).createSync();
      expect(setUpAgents(project, ['codex', 'claude', 'codex']), [
        'codex',
        'claude',
      ]);
      expect(setUpAgents(project, ['claude']), ['claude']);
      expect(setUpAgents(project, []), isEmpty);
    });
  });

  group('PackageSkillsRecord', () {
    late String project;

    setUp(() => project = tempDir().path);

    const record = PackageSkillsRecord(
      pubspec: 'aa',
      lock: null,
      agents: ['claude', 'codex'],
      version: '1.0.3',
      succeeded: true,
    );

    void writeRecord(String text) => File(packageSkillsRecordPath(project))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);

    test('lives in .dart_tool/appstein/', () {
      expect(
        packageSkillsRecordPath(project),
        p.join(project, '.dart_tool', 'appstein', 'package_skills.json'),
      );
    });

    test('reads back what toJson wrote, a null lock included', () {
      writeRecord(jsonEncode(record.toJson()));
      final read = PackageSkillsRecord.read(project)!;
      expect(read.pubspec, 'aa');
      expect(read.lock, isNull);
      expect(read.agents, ['claude', 'codex']);
      expect(read.version, '1.0.3');
      expect(read.succeeded, isTrue);
    });

    test('a missing, damaged or foreign record reads as none', () {
      expect(PackageSkillsRecord.read(project), isNull);
      for (final text in [
        'not json',
        '[]',
        '{"pubspec": "aa"}',
        '{"pubspec": 1, "lock": null, "agents": [], "version": "1.0.3", '
            '"succeeded": true}',
        '{"pubspec": "aa", "lock": null, "agents": [1], "version": "1.0.3", '
            '"succeeded": true}',
        '{"pubspec": "aa", "lock": null, "agents": [], "version": "1.0.3", '
            '"succeeded": "yes"}',
      ]) {
        writeRecord(text);
        expect(PackageSkillsRecord.read(project), isNull, reason: text);
      }
    });

    test('a folder where the record should be reads as none', () {
      Directory(packageSkillsRecordPath(project)).createSync(recursive: true);
      expect(PackageSkillsRecord.read(project), isNull);
    });

    test('sameInputs compares everything but succeeded', () {
      expect(record.sameInputs(record.withSucceeded(false)), isTrue);
      for (final other in [
        const PackageSkillsRecord(
          pubspec: 'bb',
          lock: null,
          agents: ['claude', 'codex'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: 'cc',
          agents: ['claude', 'codex'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: null,
          agents: ['claude'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: null,
          agents: ['claude', 'codex'],
          version: '1.0.4',
          succeeded: true,
        ),
      ]) {
        expect(record.sameInputs(other), isFalse);
      }
    });
  });

  group('packageSkillsFailure', () {
    test('a run that installed for every agent worked', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _installedBoth),
          ['claude', 'codex'],
        ),
        isNull,
      );
    });

    test('installing nothing still worked: no package ships skills', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _nothingShipped),
          ['claude', 'codex'],
        ),
        isNull,
      );
    });

    test('codex is the line package:skills prints as generic', () {
      const codexOnly = 'Installed 1 skill(s) for generic at .agents/skills.\n';
      expect(
        packageSkillsFailure(const RunResult(exitCode: 0, stdout: codexOnly), [
          'codex',
        ]),
        isNull,
      );
      expect(
        packageSkillsFailure(const RunResult(exitCode: 0, stdout: codexOnly), [
          'claude',
        ]),
        startsWith('it did not report installing skills for claude'),
      );
    });

    test('a usage error that exits 0 failed, with its first lines', () {
      final failure = packageSkillsFailure(
        const RunResult(exitCode: 0, stdout: _badAgent),
        ['claude'],
      );
      expect(failure, startsWith('it did not report installing skills for '));
      expect(failure, contains('is not an allowed value'));
    });

    test('a failed internal pub get that exits 0 failed', () {
      final failure = packageSkillsFailure(
        const RunResult(exitCode: 0, stdout: _pubGetFailed),
        ['claude', 'codex'],
      );
      expect(failure, contains('claude, codex'));
      expect(failure, contains('Failed to run pub get.'));
    });

    test('a non-zero exit failed, with what it printed on stderr', () {
      final failure = packageSkillsFailure(
        const RunResult(
          exitCode: 255,
          stderr:
              'Got socket error trying to find package skills at '
              'https://pub.dev.\n',
        ),
        ['claude'],
      );
      expect(failure, startsWith('it failed with exit code 255:'));
      expect(failure, contains('Got socket error'));
    });

    test('a run that did not start or timed out failed, saying so', () {
      expect(
        packageSkillsFailure(
          const RunResult.notStarted('The system cannot find the file'),
          ['claude'],
        ),
        'Dart could not be started (The system cannot find the file)',
      );
      expect(
        packageSkillsFailure(
          const RunResult.timedOut(stdout: '', stderr: 'Timed out'),
          ['claude'],
        ),
        'it did not finish within 120 s',
      );
    });

    test('only the first 10 lines of output are quoted', () {
      final long = [for (var i = 1; i <= 30; i++) 'line $i'].join('\n');
      final failure = packageSkillsFailure(
        RunResult(exitCode: 1, stdout: long),
        ['claude'],
      )!;
      expect(failure, contains('line 10'));
      expect(failure, isNot(contains('line 11')));
    });
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/skills/package_skills_test.dart`
Expected: FAIL to compile, with errors like `The function 'setUpAgents' isn't defined` and `Undefined name 'PackageSkillsRecord'`.

- [ ] **Step 3: Write the implementation**

Create `packages/appstein_engine/lib/src/skills/package_skills.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/process_runner.dart';
import '../knowledge/canonical_json.dart';

/// The version of package:skills that `sync` runs (spec §6.6), pinned
/// exactly; it moves with Appstein releases.
const packageSkillsVersion = '1.0.3';

/// How long a package skills run may take before it is stopped (spec §6.6).
const packageSkillsTimeout = Duration(seconds: 120);

/// Where `sync` records its last package skills run (spec §6.6): next to the
/// analyzer cache, in `.dart_tool/appstein/`, so it is never committed.
String packageSkillsRecordPath(String projectRoot) =>
    p.join(projectRoot, '.dart_tool', 'appstein', 'package_skills.json');

/// The agents of [configured] (`integrations.agents`) that are set up in the
/// project at [projectRoot], each once, in [configured]'s order (spec §6.6):
/// - `claude` when `.claude/` is a folder;
/// - `codex` when `.agents/` is a folder or `AGENTS.md` is a file.
///
/// Any other name is left out.
List<String> setUpAgents(String projectRoot, List<String> configured) {
  bool folder(String name) =>
      Directory(p.join(projectRoot, name)).existsSync();
  return [
    for (final agent in configured.toSet())
      if (switch (agent) {
        'claude' => folder('.claude'),
        'codex' =>
          folder('.agents') ||
              File(p.join(projectRoot, 'AGENTS.md')).existsSync(),
        _ => false,
      })
        agent,
  ];
}

/// What `sync` ran package:skills for last time (spec §6.6), stored in
/// [packageSkillsRecordPath]. A run is due when the inputs differ
/// ([sameInputs]).
final class PackageSkillsRecord {
  /// Creates the record.
  const PackageSkillsRecord({
    required this.pubspec,
    required this.lock,
    required this.agents,
    required this.version,
    required this.succeeded,
  });

  /// The SHA-256 of `pubspec.yaml`; null when there was none.
  final String? pubspec;

  /// The SHA-256 of `pubspec.lock`; null when there was none.
  final String? lock;

  /// The agents it ran for; empty when none was set up.
  final List<String> agents;

  /// The package:skills version.
  final String version;

  /// Whether the run worked. A record with no agents always counts as
  /// worked: there was nothing to run.
  final bool succeeded;

  /// The record of the project at [projectRoot]; null when there is none or
  /// it can't be read, so that a damaged record means one more run.
  static PackageSkillsRecord? read(String projectRoot) {
    try {
      final json = jsonDecode(
        File(packageSkillsRecordPath(projectRoot)).readAsStringSync(),
      );
      if (json case {
        'pubspec': final String? pubspec,
        'lock': final String? lock,
        'agents': final List<Object?> agents,
        'version': final String version,
        'succeeded': final bool succeeded,
      } when agents.every((agent) => agent is String)) {
        return PackageSkillsRecord(
          pubspec: pubspec,
          lock: lock,
          agents: agents.cast<String>(),
          version: version,
          succeeded: succeeded,
        );
      }
    } on FileSystemException {
      // Missing, a folder, or unreadable: no record.
    } on FormatException {
      // Not JSON: no record.
    }
    return null;
  }

  /// Whether [other] has the same inputs: the hashes, the agents (in order)
  /// and the version. [succeeded] is not an input.
  bool sameInputs(PackageSkillsRecord other) =>
      pubspec == other.pubspec &&
      lock == other.lock &&
      version == other.version &&
      agents.length == other.agents.length &&
      [
        for (var i = 0; i < agents.length; i++) agents[i] == other.agents[i],
      ].every((same) => same);

  /// This record with [succeeded].
  PackageSkillsRecord withSucceeded(bool succeeded) => PackageSkillsRecord(
    pubspec: pubspec,
    lock: lock,
    agents: agents,
    version: version,
    succeeded: succeeded,
  );

  /// The JSON form, as stored.
  Map<String, Object?> toJson() => {
    'pubspec': pubspec,
    'lock': lock,
    'agents': agents,
    'version': version,
    'succeeded': succeeded,
  };

  /// The text stored in the record file.
  String toText() => canonicalJson(toJson());
}

/// The name package:skills prints for [agent]: Codex is its `generic`
/// agent.
String _printedName(String agent) => agent == 'codex' ? 'generic' : agent;

/// Why the package skills run that gave [result] for [agents] failed, or
/// null when it worked.
///
/// package:skills exits 0 on most errors (an unknown agent, a failed
/// `pub get`, a usage error), so a run worked only when it exited 0 and
/// printed `Installed N skill(s) for <agent> at …` for every agent, N being
/// 0 when no package ships skills. The reason quotes the first 10 lines of
/// what it printed.
String? packageSkillsFailure(RunResult result, List<String> agents) {
  if (!result.started) {
    return 'Dart could not be started (${result.stderr.trim()})';
  }
  if (result.timedOut) {
    return 'it did not finish within ${packageSkillsTimeout.inSeconds} s';
  }
  final printed = [
    result.stdout.trim(),
    result.stderr.trim(),
  ].where((text) => text.isNotEmpty).join('\n');
  if (result.exitCode != 0) {
    return 'it failed with exit code ${result.exitCode}${_quote(printed)}';
  }
  final lines = const LineSplitter().convert(result.stdout);
  final missing = [
    for (final agent in agents)
      if (!lines.any(
        RegExp(
          '^Installed \\d+ skill\\(s\\) for ${_printedName(agent)} at ',
        ).hasMatch,
      ))
        agent,
  ];
  if (missing.isEmpty) return null;
  return 'it did not report installing skills for ${missing.join(', ')}'
      '${_quote(printed)}';
}

/// [printed] as `:` and its first 10 lines, each indented, or nothing when
/// it is empty.
String _quote(String printed) {
  if (printed.isEmpty) return '';
  final lines = const LineSplitter().convert(printed).take(10);
  return ':\n${lines.map((line) => '  $line').join('\n')}';
}
```

Add to `packages/appstein_engine/lib/appstein_engine.dart`, keeping the exports sorted by path:

```dart
export 'src/skills/package_skills.dart';
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/skills/package_skills_test.dart`
Expected: PASS, all tests.

- [ ] **Step 5: Analyze, then commit**

Run: `cd packages/appstein_engine && fvm dart analyze --fatal-infos && fvm dart format --output=none --set-exit-if-changed lib test`
Expected: `No issues found!` and no files listed.

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add packages/appstein_engine/lib/src/skills/package_skills.dart packages/appstein_engine/lib/appstein_engine.dart packages/appstein_engine/test/skills/package_skills_test.dart
git commit -m "feat(engine): package skills agents, record and run judging"
```

The commit message body ends with the trailers from Global Constraints. If `check_guide --since main` asks for a page for the new file, Task 6 adds it; until then the commit carries `Docs-Checked: knowledge-store.md - package skills get their own page in Task 6`.

---

### Task 2: `PackageSkills.refresh`

**Files:**
- Modify: `packages/appstein_engine/lib/src/skills/package_skills.dart`
- Test: `packages/appstein_engine/test/skills/package_skills_test.dart` (a new group)

**Interfaces:**
- Consumes: everything Task 1 produces; `ProcessRunner`, `RunResult`; `HostOs` (`lib/src/host/host_environment.dart`); `KnowledgeLock.acquire(String folder, {Duration timeout})`, `KnowledgeLockTimeout` (`lib/src/knowledge/knowledge_lock.dart`); `replaceFile(String path, String contents)` (`lib/src/knowledge/knowledge_store.dart`); `KnowledgeWriteException` with `.reason`.
- Produces:
  - `enum PackageSkillsOutcome { refreshed, noAgents, failed }`
  - `final class PackageSkillsReport` with `const PackageSkillsReport({required PackageSkillsOutcome outcome, List<String> agents = const [], String? reason, String? recordError})` and the fields `outcome`, `agents`, `reason` (set only for `failed`), `recordError` (why the record couldn't be saved, else null).
  - `final class PackageSkills` with `const PackageSkills({required ProcessRunner runner, required HostOs os, Duration timeout = packageSkillsTimeout})` and
    `Future<PackageSkillsReport?> refresh(String projectRoot, {required String flutterRoot, required List<String> configuredAgents, required String? pubspecHash, required String? lockHash, required bool packagesReady, required bool retryFailure})`. It returns null when nothing was due or another sync is running it.
  - `String dartCommand(String flutterRoot, HostOs os)`: the SDK's `bin/dart` (`bin\dart.bat` on Windows).

- [ ] **Step 1: Write the failing tests**

Append to `packages/appstein_engine/test/skills/package_skills_test.dart`. Add `import '../support/fake_process_runner.dart';` to the imports, then this group inside `main()`:

```dart
  group('PackageSkills.refresh', () {
    late String project;
    late String flutter;
    late FakeProcessRunner runner;

    setUp(() {
      project = tempDir().path;
      flutter = p.join(tempDir().path, 'flutter');
      runner = FakeProcessRunner();
    });

    String dart() => dartCommand(flutter, HostOs.current);

    List<String> args(List<String> agents) => [
      'run',
      'skills@1.0.3',
      '-C',
      project,
      'get',
      '--all',
      for (final agent in agents) ...['--agent', agent],
    ];

    void answer(List<String> agents, RunResult result) =>
        runner.when(dart(), args(agents), result);

    Future<PackageSkillsReport?> refresh({
      List<String> configured = const ['claude', 'codex'],
      String? pubspec = 'p1',
      String? lock = 'l1',
      bool packagesReady = true,
      bool retryFailure = true,
    }) => PackageSkills(runner: runner, os: HostOs.current).refresh(
      project,
      flutterRoot: flutter,
      configuredAgents: configured,
      pubspecHash: pubspec,
      lockHash: lock,
      packagesReady: packagesReady,
      retryFailure: retryFailure,
    );

    void setUpClaude() => Directory(p.join(project, '.claude')).createSync();

    test('the command is the SDK\'s own dart', () {
      expect(
        dartCommand(r'C:\fl utter', HostOs.windows),
        p.join(r'C:\fl utter', 'bin', 'dart.bat'),
      );
      expect(
        dartCommand('/opt/flutter', HostOs.linux),
        p.join('/opt/flutter', 'bin', 'dart'),
      );
    });

    test('with no agent set up, it runs nothing, creates no agent folder, '
        'and says so once', () async {
      final first = await refresh();
      expect(first?.outcome, PackageSkillsOutcome.noAgents);
      expect(runner.calls, isEmpty);
      expect(Directory(p.join(project, '.claude')).existsSync(), isFalse);
      expect(Directory(p.join(project, '.agents')).existsSync(), isFalse);
      expect(await refresh(), isNull);
      expect(runner.calls, isEmpty);
    });

    test('a first run installs for the set-up agents and records it',
        () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final report = await refresh();
      expect(report?.outcome, PackageSkillsOutcome.refreshed);
      expect(report?.agents, ['claude']);
      expect(report?.recordError, isNull);
      expect(runner.calls, ['${dart()} ${args(['claude']).join(' ')}']);
      expect(runner.workingDirectories, [project]);
      final record = PackageSkillsRecord.read(project)!;
      expect(record.succeeded, isTrue);
      expect(record.agents, ['claude']);
      expect(record.pubspec, 'p1');
      expect(record.lock, 'l1');
      expect(record.version, packageSkillsVersion);
    });

    test('unchanged inputs run nothing', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      await refresh();
      expect(await refresh(), isNull);
      expect(await refresh(retryFailure: false), isNull);
      expect(runner.calls, hasLength(1));
    });

    test('a changed pubspec.yaml, pubspec.lock or agent list runs again',
        () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      await refresh();
      await refresh(pubspec: 'p2');
      await refresh(pubspec: 'p2', lock: 'l2');
      expect(runner.calls, hasLength(3));
      File(p.join(project, 'AGENTS.md')).writeAsStringSync('# Agents\n');
      answer(
        ['claude', 'codex'],
        const RunResult(exitCode: 0, stdout: _installedBoth),
      );
      final report = await refresh(pubspec: 'p2', lock: 'l2');
      expect(report?.agents, ['claude', 'codex']);
      expect(runner.calls, hasLength(4));
    });

    test('a failure is a warning with the reason, recorded as failed',
        () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _badAgent));
      final report = await refresh();
      expect(report?.outcome, PackageSkillsOutcome.failed);
      expect(report?.reason, contains('is not an allowed value'));
      expect(PackageSkillsRecord.read(project)!.succeeded, isFalse);
    });

    test('a full sync retries a failure; detect does not', () async {
      setUpClaude();
      answer(
        ['claude'],
        const RunResult(exitCode: 255, stderr: 'Got socket error'),
      );
      await refresh();
      expect(await refresh(retryFailure: false), isNull);
      expect(runner.calls, hasLength(1));
      final again = await refresh();
      expect(again?.outcome, PackageSkillsOutcome.failed);
      expect(runner.calls, hasLength(2));
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
      expect(await refresh(), isNull);
      expect(runner.calls, hasLength(3));
    });

    test('detect still runs when the inputs changed after a failure',
        () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 1));
      await refresh();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final report = await refresh(lock: 'l2', retryFailure: false);
      expect(report?.outcome, PackageSkillsOutcome.refreshed);
    });

    test('packages that could not be fetched fail without a run', () async {
      setUpClaude();
      final report = await refresh(packagesReady: false);
      expect(report?.outcome, PackageSkillsOutcome.failed);
      expect(report?.reason, 'the packages could not be fetched');
      expect(runner.calls, isEmpty);
      expect(PackageSkillsRecord.read(project)!.succeeded, isFalse);
    });

    test('while another sync holds the lock, it prints nothing and runs '
        'nothing, without waiting', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final held = await KnowledgeLock.acquire(
        p.dirname(packageSkillsRecordPath(project)),
      );
      addTearDown(held.release);
      final watch = Stopwatch()..start();
      expect(await refresh(), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(runner.calls, isEmpty);
      held.release();
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
    });

    test('a record that cannot be saved is reported with the outcome',
        () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      // A folder where the record file goes makes the rename fail.
      Directory(packageSkillsRecordPath(project)).createSync(recursive: true);
      final report = await refresh();
      expect(report?.outcome, PackageSkillsOutcome.refreshed);
      expect(report?.recordError, isNotNull);
    });

    test('a damaged record means one more run', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      await refresh();
      File(packageSkillsRecordPath(project)).writeAsStringSync('{');
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
      expect(runner.calls, hasLength(2));
    });
  });
```

Add this constant next to the other captured outputs at the top of the file:

```dart
const _claudeOnly =
    '  [claude] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for claude at .claude/skills.\n';
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/skills/package_skills_test.dart`
Expected: FAIL to compile: `Undefined name 'dartCommand'`, `Undefined class 'PackageSkillsReport'`, `The method 'PackageSkills' isn't defined`.

- [ ] **Step 3: Write the implementation**

Add these imports to `package_skills.dart` (keep them sorted):

```dart
import '../host/host_environment.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';
```

Append to `package_skills.dart`:

```dart
/// The `dart` command of the Flutter SDK at [flutterRoot]: `bin/dart`, or
/// `bin\dart.bat` on Windows. Never the `dart` on PATH, which may be another
/// SDK.
String dartCommand(String flutterRoot, HostOs os) =>
    p.join(flutterRoot, 'bin', os == HostOs.windows ? 'dart.bat' : 'dart');

/// What a package skills refresh did.
enum PackageSkillsOutcome {
  /// package:skills ran and installed the skills for [PackageSkillsReport.agents].
  refreshed,

  /// No agent in `integrations.agents` is set up in the project, so nothing
  /// ran.
  noAgents,

  /// The run failed or couldn't start; [PackageSkillsReport.reason] says
  /// why.
  failed,
}

/// What `sync` did about package skills (spec §6.6).
final class PackageSkillsReport {
  /// Creates the report.
  const PackageSkillsReport({
    required this.outcome,
    this.agents = const [],
    this.reason,
    this.recordError,
  });

  /// What happened.
  final PackageSkillsOutcome outcome;

  /// The agents it ran for; empty for [PackageSkillsOutcome.noAgents].
  final List<String> agents;

  /// Why it failed; set only for [PackageSkillsOutcome.failed].
  final String? reason;

  /// Why the record couldn't be saved, so the next sync runs package:skills
  /// again; null when it was saved.
  final String? recordError;
}

/// Runs package:skills for a project when its dependencies changed (spec
/// §6.6).
final class PackageSkills {
  /// Creates the refresher. [runner] runs `dart`, on [os].
  const PackageSkills({
    required this.runner,
    required this.os,
    this.timeout = packageSkillsTimeout,
  });

  /// Runs `dart run skills@…`.
  final ProcessRunner runner;

  /// The operating system, which names the `dart` command.
  final HostOs os;

  /// How long a run may take before it is stopped.
  final Duration timeout;

  /// Runs package:skills for the project at [projectRoot] when it is due,
  /// with the Flutter SDK at [flutterRoot].
  ///
  /// It is due when the record ([PackageSkillsRecord]) is missing or has
  /// other inputs: [pubspecHash], [lockHash], the agents of
  /// [configuredAgents] that are set up ([setUpAgents]) and
  /// [packageSkillsVersion]. A failed run with the same inputs is due again
  /// only when [retryFailure] is true (a full sync, not `--detect`).
  ///
  /// With no agent set up, it runs nothing and records that, so it reports
  /// [PackageSkillsOutcome.noAgents] once per change. When the packages
  /// couldn't be fetched ([packagesReady] false), it fails without running.
  /// When another sync holds the lock on `.dart_tool/appstein/`, it returns
  /// null at once: that sync is running it.
  ///
  /// Returns null when nothing was due. Never throws for a failed run or a
  /// file it can't write; those are in the report.
  Future<PackageSkillsReport?> refresh(
    String projectRoot, {
    required String flutterRoot,
    required List<String> configuredAgents,
    required String? pubspecHash,
    required String? lockHash,
    required bool packagesReady,
    required bool retryFailure,
  }) async {
    final agents = setUpAgents(projectRoot, configuredAgents);
    final wanted = PackageSkillsRecord(
      pubspec: pubspecHash,
      lock: lockHash,
      agents: agents,
      version: packageSkillsVersion,
      succeeded: true,
    );
    bool due(PackageSkillsRecord? last) =>
        last == null ||
        !last.sameInputs(wanted) ||
        (!last.succeeded && retryFailure);
    if (!due(PackageSkillsRecord.read(projectRoot))) return null;
    if (agents.isEmpty) {
      return PackageSkillsReport(
        outcome: PackageSkillsOutcome.noAgents,
        recordError: await _save(projectRoot, wanted),
      );
    }
    if (!packagesReady) {
      return _failed(
        projectRoot,
        wanted,
        agents,
        'the packages could not be fetched',
      );
    }
    final KnowledgeLock lock;
    try {
      lock = await KnowledgeLock.acquire(
        p.dirname(packageSkillsRecordPath(projectRoot)),
        timeout: Duration.zero,
      );
    } on KnowledgeLockTimeout {
      return null;
    } on KnowledgeWriteException catch (error) {
      return PackageSkillsReport(
        outcome: PackageSkillsOutcome.failed,
        agents: agents,
        reason: 'its lock could not be created (${error.reason})',
      );
    }
    try {
      // Another sync may have finished a run since the check above.
      if (!due(PackageSkillsRecord.read(projectRoot))) return null;
      final result = await runner.run(
        dartCommand(flutterRoot, os),
        [
          'run',
          'skills@$packageSkillsVersion',
          '-C',
          projectRoot,
          'get',
          '--all',
          for (final agent in agents) ...['--agent', agent],
        ],
        timeout: timeout,
        workingDirectory: projectRoot,
      );
      final failure = packageSkillsFailure(result, agents);
      if (failure != null) {
        return _failed(projectRoot, wanted, agents, failure);
      }
      return PackageSkillsReport(
        outcome: PackageSkillsOutcome.refreshed,
        agents: agents,
        recordError: await _save(projectRoot, wanted),
      );
    } finally {
      lock.release();
    }
  }

  Future<PackageSkillsReport> _failed(
    String projectRoot,
    PackageSkillsRecord wanted,
    List<String> agents,
    String reason,
  ) async => PackageSkillsReport(
    outcome: PackageSkillsOutcome.failed,
    agents: agents,
    reason: reason,
    recordError: await _save(projectRoot, wanted.withSucceeded(false)),
  );

  /// Saves [record]; returns why it couldn't, or null.
  Future<String?> _save(String projectRoot, PackageSkillsRecord record) async {
    try {
      await replaceFile(packageSkillsRecordPath(projectRoot), record.toText());
      return null;
    } on KnowledgeWriteException catch (error) {
      return error.reason;
    }
  }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/skills/package_skills_test.dart`
Expected: PASS, all tests (Task 1's and Task 2's).

If "a record that cannot be saved" fails because `replaceFile` waits its default 2 s of rename retries, that is expected and still passes; if it fails because no `KnowledgeWriteException` is thrown on this OS, read `_replace` in `knowledge_store.dart` and make the test's obstacle one that throws there (record the change as a ruling).

- [ ] **Step 5: Analyze, then commit**

Run: `cd packages/appstein_engine && fvm dart analyze --fatal-infos && fvm dart format --output=none --set-exit-if-changed lib test`
Expected: `No issues found!` and no files listed.

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add packages/appstein_engine/lib/src/skills/package_skills.dart packages/appstein_engine/test/skills/package_skills_test.dart
git commit -m "feat(engine): PackageSkills.refresh runs package:skills when due"
```

---

### Task 3: Wire package skills into `KnowledgeSync`

**Files:**
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` (constructor, `_rebuild`, `detect`)
- Modify: `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` (`SyncReport` gets `packageSkills`)
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_package_skills_test.dart`

**Interfaces:**
- Consumes: `PackageSkills`, `PackageSkillsReport`, `PackageSkillsOutcome`, `dartCommand`, `packageSkillsRecordPath`, `PackageSkillsRecord` (Tasks 1–2); `PackagesAction` (`map_sync.dart`); the map inputs' `sources['pubspec.yaml']` and `sources['pubspec.lock']` (`map_inputs.dart:57-58`).
- Produces:
  - `KnowledgeSync({…, List<String> agents = const ['claude', 'codex']})` and the field `final List<String> agents;`
  - `SyncReport({…, PackageSkillsReport? packageSkills})` and the field `final PackageSkillsReport? packageSkills;` (null when nothing was due).
  - A timing step named `package skills` in every `run` and `detect`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/knowledge/knowledge_sync_package_skills_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/temp.dart';
import 'support/sync_harness.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;
  late String app;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
    app = copyFixtureApp();
  });

  KnowledgeSync sync({List<String> agents = const ['claude', 'codex']}) =>
      KnowledgeSync(
        environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
        appsteinVersion: '0.1.0-dev',
        packs: const [OfficialMvvmPack()],
        runner: runner,
        clock: () => DateTime.utc(2026, 10, 1, 9),
        agents: agents,
      );

  List<String> skillsArgs(List<String> agents) => [
    'run',
    'skills@1.0.3',
    '-C',
    app,
    'get',
    '--all',
    for (final agent in agents) ...['--agent', agent],
  ];

  void answerSkills(List<String> agents, RunResult result) =>
      runner.when(dartCommand(sdk, HostOs.current), skillsArgs(agents), result);

  List<String> skillsCalls() =>
      runner.calls.where((call) => call.contains('skills@')).toList();

  const installed = 'Installed 0 skill(s) for claude at .claude/skills.\n';

  test('with no agent set up, the first sync says so and later ones say '
      'nothing', () async {
    final first = await sync().run(app, dartSdkPath: testDartSdk);
    expect(first.packageSkills?.outcome, PackageSkillsOutcome.noAgents);
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.packageSkills, isNull);
    expect(skillsCalls(), isEmpty);
  });

  test('a sync runs package:skills after writing the knowledge, and the '
      'record holds the hashes the map read', () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
    expect(skillsCalls(), hasLength(1));
    expect(report.timings.keys, contains('package skills'));
    final record = PackageSkillsRecord.read(app)!;
    expect(record.pubspec, isNotNull);
    expect(record.lock, isNotNull);
    // The knowledge was written before the run.
    expect(File(p.join(app, '.appstein', 'INDEX.md')).existsSync(), isTrue);
  });

  test('a failed run is a warning; the sync and its files are unaffected',
      () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 255));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.failed);
    expect(report.files[indexPath], isTrue);
  });

  test('a current detect retries nothing after a failure; a full sync does',
      () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 255));
    await sync().run(app, dartSdkPath: testDartSdk);
    final detected = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(detected.current, isTrue);
    expect(detected.packageSkills, isNull);
    expect(detected.timings.keys, contains('package skills'));
    expect(skillsCalls(), hasLength(1));
    final full = await sync().run(app, dartSdkPath: testDartSdk);
    expect(full.packageSkills?.outcome, PackageSkillsOutcome.failed);
    expect(skillsCalls(), hasLength(2));
  });

  test('a current detect runs it when an agent was set up since', () async {
    await sync().run(app, dartSdkPath: testDartSdk);
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    final detected = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(detected.current, isTrue);
    expect(detected.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
  });

  test('a detect that rebuilds for a pubspec change runs it again', () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    await sync().run(app, dartSdkPath: testDartSdk);
    // An edited pubspec.yaml makes the packages stale, so the rebuild runs
    // `flutter pub get` first; the stub packages are still in place.
    runner.when(flutterCommand(sdk), const [
      'pub',
      'get',
    ], const RunResult(exitCode: 0));
    File(p.join(app, 'pubspec.yaml')).writeAsStringSync(
      '\n# a comment\n',
      mode: FileMode.append,
    );
    final detected = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(detected.current, isFalse);
    expect(detected.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
    expect(skillsCalls(), hasLength(2));
  });

  test('only agents in integrations.agents count', () async {
    Directory(p.join(app, '.claude')).createSync();
    final report = await sync(
      agents: const ['codex'],
    ).run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.noAgents);
    expect(skillsCalls(), isEmpty);
  });

  test('a failed pub get fails package skills without running them',
      () async {
    final empty = tempDir().path;
    final project = p.join(empty, 'app');
    Directory(project).createSync();
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync(
      'name: sample\nenvironment:\n  sdk: ^3.12.0\n',
    );
    Directory(p.join(project, '.claude')).createSync();
    // flutter pub get isn't faked, so it "fails to start".
    final report = await sync().run(project, dartSdkPath: testDartSdk);
    expect(report.map?.packages, PackagesAction.fetchFailed);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.failed);
    expect(report.packageSkills?.reason, 'the packages could not be fetched');
    expect(skillsCalls(), isEmpty);
  });
}
```

`copyFixtureApp()` (`test/support/fixture_app.dart`) writes stub packages that count as fresh, so a sync of the fixture runs no `flutter pub get` until `pubspec.yaml` changes; the pubspec test fakes it the way `knowledge_sync_detect_test.dart`'s "pubspec.yaml edited" test does. In the last test, the bare project has no stubs, and `flutter pub get` isn't faked, so it fails to start.

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_package_skills_test.dart`
Expected: FAIL to compile: `No named parameter with the name 'agents'` and `The getter 'packageSkills' isn't defined for the type 'SyncReport'`.

- [ ] **Step 3: Write the implementation**

In `platform_sync.dart`, import the package skills file and add the field to `SyncReport`:

```dart
import '../skills/package_skills.dart';
```

```dart
  const SyncReport({
    required this.sdk,
    required this.files,
    required this.newestNotes,
    required this.fallbacks,
    this.map,
    this.native,
    this.analyzerCache,
    this.packageSkills,
    this.current = false,
    this.changed = const [],
    this.rebuiltBecause = const [],
    this.timings = const {},
  });

  /// What the sync did about package skills (spec §6.6); null when nothing
  /// was due, another sync was running them, or only the platform layer was
  /// synced.
  final PackageSkillsReport? packageSkills;
```

In `knowledge_sync.dart`:

1. Import `'../skills/package_skills.dart';` (sorted with the others).
2. Constructor: add `this.agents = const ['claude', 'codex'],` after `this.analyzerCache = true,`, and document it in the constructor comment ("[agents] is `integrations.agents` from `appstein.yaml`"). Add the field:

```dart
  /// The agents `integrations.agents` names (spec §7); package skills are
  /// installed for those already set up in the project (spec §6.6). The
  /// default is the config's default.
  final List<String> agents;
```

3. Add a private helper at the end of the class:

```dart
  /// Runs package skills (spec §6.6) after the knowledge is written, timed
  /// as `package skills`. [sources] are the map's inputs, after any fetch.
  Future<PackageSkillsReport?> _packageSkills(
    String projectRoot,
    PlatformBuild platform,
    Map<String, String?> sources, {
    required bool packagesReady,
    required bool retryFailure,
    required SyncTimings timings,
  }) => timings.timeAsync(
    'package skills',
    () => PackageSkills(runner: runner, os: environment.os).refresh(
      projectRoot,
      flutterRoot: platform.location.root,
      configuredAgents: agents,
      pubspecHash: sources['pubspec.yaml'],
      lockHash: sources['pubspec.lock'],
      packagesReady: packagesReady,
      retryFailure: retryFailure,
    ),
  );
```

Check the type of `MapInputs.sources` in `map_inputs.dart` (it is built as `<String, String?>{…}`); if the field is declared with another type, use that type here.

4. `_rebuild` gets a `required bool retryFailure` parameter. `run` passes `retryFailure: true`; `detect`'s rebuild passes `retryFailure: false`. Change the end of `_rebuild` so the locked block returns the written files and the cache save error, and the report is built after package skills:

```dart
    final asked = Stopwatch()..start();
    final (files, saveError) = await store.locked(() async {
      timings.add('lock wait', asked.elapsed);
      final files = await timings.timeAsync(
        'knowledge write',
        () => store.writeAll(
          [...platform.files, delta, ...map.files, ?native.file, index],
          appsteinVersion: appsteinVersion,
          sdkVersion: platform.sdk.flutterVersion,
          sources: sources,
          changed: changed,
        ),
      );
      // (the existing analyzer-cache save block, unchanged, setting saveError)
      return (files, saveError);
    }, timeout: lockTimeout);
    // After the knowledge and outside its lock: a run can take seconds, and
    // the knowledge never depends on it.
    final skills = await _packageSkills(
      projectRoot,
      platform,
      sources,
      packagesReady: map.report.packages != PackagesAction.fetchFailed,
      retryFailure: retryFailure,
      timings: timings,
    );
    return SyncReport(
      sdk: platform.sdk,
      files: files,
      newestNotes: platform.newestNotes,
      fallbacks: platform.fallbacks,
      map: map.report,
      native: native.report,
      packageSkills: skills,
      changed: previous == null ? const [] : changed,
      rebuiltBecause: reasons,
      analyzerCache: cache == null
          ? null
          : AnalyzerCacheReport(
              load: cache.load,
              damage: cache.damage,
              retried: map.cacheRetry,
              saveError: saveError,
            ),
      timings: timings.steps,
    );
```

Keep the existing comments on the analyzer-cache save and on `changed` (`// With no earlier state there is nothing to compare with.`).

5. In `detect`, the current branch: before building its report, run package skills with the prepared inputs. The packages are fresh there (freshness found the knowledge current, which needs fresh packages):

```dart
    final platform = prepared.platform;
    final skills = await _packageSkills(
      projectRoot,
      platform,
      prepared.mapInputs.sources,
      packagesReady: true,
      retryFailure: false,
      timings: timings,
    );
    return SyncReport(
      sdk: platform.sdk,
      files: const {},
      newestNotes: platform.newestNotes,
      fallbacks: platform.fallbacks,
      packageSkills: skills,
      current: true,
      timings: timings.steps,
    );
```

6. Update the doc comments of `run` and `detect`: `run` "then runs package skills when the dependencies or agents changed, retrying a failed run (spec §6.6); the result is in [SyncReport.packageSkills]"; `detect` "also runs package skills when due, but doesn't retry a failed run with the same inputs".

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_package_skills_test.dart`
Expected: PASS.

Then the whole engine suite, because every sync now writes `.dart_tool/appstein/package_skills.json` (the "nothing changed" snapshot tests include that folder):

Run: `cd packages/appstein_engine && fvm dart test`
Expected: PASS. If a snapshot test fails because the first sync wrote the record and a later detect compares, read the test: a detect with unchanged inputs must write nothing, so a failure there is a bug in Step 3, not in the test.

- [ ] **Step 5: Analyze, then commit**

Run: `cd packages/appstein_engine && fvm dart analyze --fatal-infos && fvm dart format --output=none --set-exit-if-changed lib test`
Expected: `No issues found!` and no files listed.

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart packages/appstein_engine/lib/src/knowledge/platform_sync.dart packages/appstein_engine/test/knowledge/knowledge_sync_package_skills_test.dart
git commit -m "feat(engine): sync runs package skills after writing the knowledge"
```

With `Docs-Checked:` trailers for the pages covering `knowledge_sync.dart` and `platform_sync.dart` (find them with `grep -l "knowledge_sync.dart\|platform_sync.dart" docs/guide/*.md` among the `covers:` comments), saying Task 6 updates them.

---

### Task 4: The CLI passes the agents and prints one line

**Files:**
- Modify: `packages/appstein_cli/lib/src/sync_command.dart`
- Test: `packages/appstein_cli/test/sync_command_test.dart`

**Interfaces:**
- Consumes: `SyncReport.packageSkills`, `PackageSkillsReport`, `PackageSkillsOutcome` (exported by `package:appstein_engine/appstein_engine.dart`); `AppsteinConfig.integrations.agents`.
- Produces: `String formatPackageSkills(PackageSkillsReport report)` (public, so the tests and the guide can name it); `formatSyncReport` adds its line.

The exact lines (spec §6.6):
- refreshed: `Package skills: refreshed for claude, codex.`
- noAgents: `Package skills: skipped, because no agent in integrations.agents is set up in this project (claude needs .claude/; codex needs .agents/ or AGENTS.md).`
- failed: `warning: package skills could not be refreshed (<reason>); the next appstein sync tries again.` A multi-line reason keeps its first line in the parentheses and prints the rest indented below, as the fetch failure does.
- recordError (with any outcome): an extra line `warning: the package skills record could not be saved (<recordError>), so the next sync runs package:skills again.`

- [ ] **Step 1: Write the failing tests**

Add to `packages/appstein_cli/test/sync_command_test.dart`, next to the other `formatSyncReport` tests (the file already imports the engine and protocol libraries that define `SyncReport`, `SdkInfo` and `NotesCoverage`):

```dart
  group('package skills', () {
    SyncReport withSkills(PackageSkillsReport? skills, {bool current = false}) =>
        SyncReport(
          sdk: const SdkInfo(
            flutterVersion: '3.47.5',
            dartVersion: '3.13.4',
            channel: 'stable',
            notesCoverage: NotesCoverage.complete,
          ),
          files: const {},
          newestNotes: '3.47',
          fallbacks: const [],
          current: current,
          packageSkills: skills,
        );

    test('refreshed names the agents', () {
      expect(
        formatSyncReport(
          withSkills(
            const PackageSkillsReport(
              outcome: PackageSkillsOutcome.refreshed,
              agents: ['claude', 'codex'],
            ),
          ),
        ),
        contains('Package skills: refreshed for claude, codex.\n'),
      );
    });

    test('no agent set up says what each agent needs', () {
      expect(
        formatSyncReport(
          withSkills(
            const PackageSkillsReport(outcome: PackageSkillsOutcome.noAgents),
          ),
        ),
        contains(
          'Package skills: skipped, because no agent in integrations.agents '
          'is set up in this project (claude needs .claude/; codex needs '
          '.agents/ or AGENTS.md).\n',
        ),
      );
    });

    test('a failure is a warning; a long reason is indented below', () {
      final text = formatSyncReport(
        withSkills(
          const PackageSkillsReport(
            outcome: PackageSkillsOutcome.failed,
            agents: ['claude'],
            reason:
                'it failed with exit code 255:\n  Got socket error trying to '
                'find package skills',
          ),
        ),
      );
      expect(
        text,
        contains(
          'warning: package skills could not be refreshed (it failed with '
          'exit code 255:); the next appstein sync tries again.\n'
          '    Got socket error trying to find package skills\n',
        ),
      );
    });

    test('a record that could not be saved adds a warning', () {
      expect(
        formatSyncReport(
          withSkills(
            const PackageSkillsReport(
              outcome: PackageSkillsOutcome.refreshed,
              agents: ['claude'],
              recordError: 'Access is denied.',
            ),
          ),
        ),
        contains(
          'warning: the package skills record could not be saved (Access is '
          'denied.), so the next sync runs package:skills again.\n',
        ),
      );
    });

    test('a current report keeps its one line, then the package skills line',
        () {
      final text = formatSyncReport(
        withSkills(
          const PackageSkillsReport(
            outcome: PackageSkillsOutcome.refreshed,
            agents: ['claude'],
          ),
          current: true,
        ),
      );
      final lines = text.trimRight().split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('Knowledge is current for Flutter'));
      expect(lines.last, 'Package skills: refreshed for claude.');
    });

    test('nothing due adds no line', () {
      expect(formatSyncReport(withSkills(null)), isNot(contains('Package skills')));
      expect(
        formatSyncReport(withSkills(null, current: true)).trimRight().split('\n'),
        hasLength(1),
      );
    });
  });

  test('sync passes integrations.agents from appstein.yaml', () async {
    File(
      p.join(project, 'appstein.yaml'),
    ).writeAsStringSync('integrations:\n  agents: [codex]\n');
    Directory(p.join(project, '.claude')).createSync();
    expect(await run(['sync']), ExitCodes.ok, reason: '$err');
    expect(
      out.toString(),
      contains(
        'Package skills: skipped, because no agent in integrations.agents',
      ),
    );
    expect(
      Directory(p.join(project, '.agents')).existsSync(),
      isFalse,
    );
  });

  test('with the default agents and .claude/, a sync whose packages could '
      'not be fetched warns about package skills', () async {
    Directory(p.join(project, '.claude')).createSync();
    expect(await run(['sync']), ExitCodes.ok, reason: '$err');
    expect(
      out.toString(),
      contains(
        'warning: package skills could not be refreshed (the packages could '
        'not be fetched); the next appstein sync tries again.\n',
      ),
    );
  });
```

These two use this file's `run` helper (a real `appstein sync` on a project whose fake Flutter SDK can't fetch packages, so no `dart` is ever started). Put them in `main()` next to "the delta's baseline comes from appstein.yaml".

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_cli && fvm dart test test/sync_command_test.dart`
Expected: FAIL: the package skills lines are missing (and, before Task 3 is in, `packageSkills` would not compile; Task 3 is done, so the failures are the missing lines and the `codex`-only test reporting nothing about `.claude/`).

- [ ] **Step 3: Write the implementation**

In `SyncCommand.run`, pass the agents:

```dart
      final sync = KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
        baseline: config.delta.baseline,
        agents: config.integrations.agents,
      );
```

Add the formatter below `formatSyncReport`:

```dart
/// The lines `appstein sync` prints for what it did about package skills
/// (spec §6.6): one line, plus a warning when the record couldn't be saved.
/// A multi-line failure reason keeps its first line in the warning and
/// prints the rest below it, indented.
String formatPackageSkills(PackageSkillsReport report) {
  final buffer = StringBuffer();
  switch (report.outcome) {
    case PackageSkillsOutcome.refreshed:
      buffer.writeln(
        'Package skills: refreshed for ${report.agents.join(', ')}.',
      );
    case PackageSkillsOutcome.noAgents:
      buffer.writeln(
        'Package skills: skipped, because no agent in integrations.agents is '
        'set up in this project (claude needs .claude/; codex needs .agents/ '
        'or AGENTS.md).',
      );
    case PackageSkillsOutcome.failed:
      final [first, ...rest] = const LineSplitter().convert(
        report.reason ?? 'unknown reason',
      );
      buffer.writeln(
        'warning: package skills could not be refreshed ($first); the next '
        'appstein sync tries again.',
      );
      for (final line in rest) {
        buffer.writeln('  $line');
      }
  }
  if (report.recordError case final why?) {
    buffer.writeln(
      'warning: the package skills record could not be saved ($why), so the '
      'next sync runs package:skills again.',
    );
  }
  return buffer.toString();
}
```

`LineSplitter().convert` of a non-empty reason always has a first line; `packageSkillsFailure` never returns an empty string. If the analyzer rejects the list pattern as possibly not matching, use `final lines = …; final first = lines.first; final rest = lines.skip(1);`.

In `formatSyncReport`, the current branch becomes:

```dart
  if (report.current) {
    return 'Knowledge is current for Flutter ${sdk.flutterVersion} '
        '(Dart ${sdk.dartVersion}, ${sdk.channel} channel): nothing it reads '
        'changed since the last sync.\n'
        '${switch (report.packageSkills) {
          final skills? => formatPackageSkills(skills),
          null => '',
        }}';
  }
```

and, in the full report, after the native-config lines and before the analyzer-cache lines:

```dart
  if (report.packageSkills case final skills?) {
    buffer.write(formatPackageSkills(skills));
  }
```

Update `formatSyncReport`'s doc comment to mention the package skills line.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_cli && fvm dart test`
Expected: PASS, the whole CLI suite.

- [ ] **Step 5: Analyze, then commit**

Run: `cd packages/appstein_cli && fvm dart analyze --fatal-infos && fvm dart format --output=none --set-exit-if-changed lib test`
Expected: `No issues found!` and no files listed.

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add packages/appstein_cli/lib/src/sync_command.dart packages/appstein_cli/test/sync_command_test.dart
git commit -m "feat(cli): sync passes integrations.agents and reports package skills"
```

With `Docs-Checked: cli.md - Task 6 adds the package skills lines`.

---

### Task 5: Integration test against the real package:skills

**Files:**
- Create: `packages/appstein_engine/test/integration/package_skills_real_test.dart`

**Interfaces:**
- Consumes: `machineSdk` (`test/support/machine_sdk.dart`), `tempDir` (`test/support/temp.dart`), `fetchPackages` (exported), `PackageSkills`, `PackageSkillsOutcome`, `PackageSkillsRecord`, `SystemProcessRunner`, `HostEnvironment`.
- Produces: nothing other tasks use. CI's `test` job already runs every integration test in `packages/appstein_engine` (`dart test --run-skipped --tags integration`, `.github/workflows/ci.yml:81`) on Linux, macOS and Windows, so no workflow change is needed. It needs pub.dev; CI has network.

- [ ] **Step 1: Write the test**

```dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/machine_sdk.dart';
import '../support/temp.dart';

void main() {
  final environment = HostEnvironment.current();

  test('the real package:skills installs a path dependency\'s skill for '
      'Claude Code and Codex, in a folder with a space and an umlaut, and '
      'a second refresh runs nothing', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final root = tempDir().path;
    final package = p.join(root, 'skill_pkg');
    final app = p.join(root, 'my äpp');
    void write(String path, String text) => File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    write(
      p.join(package, 'pubspec.yaml'),
      'name: skill_pkg\nversion: 0.1.0\nenvironment:\n  sdk: ^3.10.0\n',
    );
    write(p.join(package, 'lib', 'skill_pkg.dart'), 'int answer() => 42;\n');
    write(
      p.join(package, 'skills', 'skill-pkg-demo', 'SKILL.md'),
      '---\nname: skill-pkg-demo\ndescription: Demo skill shipped by '
      'skill_pkg.\n---\nUse answer().\n',
    );
    write(
      p.join(app, 'pubspec.yaml'),
      'name: probe_app\nenvironment:\n  sdk: ^3.10.0\ndependencies:\n'
      '  skill_pkg:\n    path: ../skill_pkg\n',
    );
    write(p.join(app, 'lib', 'main.dart'), 'void main() {}\n');
    Directory(p.join(app, '.claude')).createSync();
    write(p.join(app, 'AGENTS.md'), '# Agents\n');

    final flutterRoot = sdk.location!.root;
    const runner = SystemProcessRunner();
    final fetch = await fetchPackages(
      app,
      flutterRoot: flutterRoot,
      os: environment.os,
      runner: runner,
    );
    expect(fetch, isNull, reason: 'flutter pub get: $fetch');

    Future<PackageSkillsReport?> refresh() =>
        PackageSkills(runner: runner, os: environment.os).refresh(
          app,
          flutterRoot: flutterRoot,
          configuredAgents: const ['claude', 'codex'],
          pubspecHash: 'p',
          lockHash: 'l',
          packagesReady: true,
          retryFailure: true,
        );

    final first = await refresh();
    expect(
      first?.outcome,
      PackageSkillsOutcome.refreshed,
      reason: first?.reason,
    );
    for (final folder in ['.claude', '.agents']) {
      expect(
        File(
          p.join(app, folder, 'skills', 'skill-pkg-demo', 'SKILL.md'),
        ).existsSync(),
        isTrue,
        reason: folder,
      );
    }
    expect(PackageSkillsRecord.read(app)?.succeeded, isTrue);
    expect(await refresh(), isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
```

- [ ] **Step 2: Run it**

Run: `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration test/integration/package_skills_real_test.dart`
Expected: PASS (the first run of `skills@1.0.3` on a machine downloads and compiles it, about 8 s). If it fails because `-C` with this path is mangled by `dart.bat`, keep the `workingDirectory` and drop `-C <projectRoot>` from the command in Task 2, update Task 2's test arguments, record a ruling, and tell the owner the spec's `-C <project>` wording needs approval to change.

- [ ] **Step 3: Commit**

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add packages/appstein_engine/test/integration/package_skills_real_test.dart
git commit -m "test(engine): package skills against the real package:skills 1.0.3"
```

---

### Task 6: Developer guide, generated docs and the graph

**Files:**
- Create: `docs/guide/package-skills.md`
- Modify: `docs/guide/README.md` (the page table, after the `incremental-sync` row)
- Modify: `docs/guide/cli.md` (the `sync` report lines)
- Modify: `docs/guide/incremental-sync.md` (detect and package skills; the `package skills` timing step)
- Modify: `docs/guide/testing.md` only if it lists the integration test files by name (check with `grep -n "integration" docs/guide/testing.md`)
- Modify: the pages that cover `knowledge_sync.dart` and `platform_sync.dart` (find them in the `covers:` comments), only where they describe what a sync does

- [ ] **Step 1: Write `docs/guide/package-skills.md`**

It starts with the covers comment, then explains, for someone learning the codebase:

```markdown
<!-- covers:
packages/appstein_engine/lib/src/skills/package_skills.dart
-->

# Package skills

Some packages ship agent skills of their own: folders under `skills/` with a `SKILL.md`. Google's package:skills copies them into an agent's skill folder. `appstein sync` runs it whenever the project's dependencies change, so the agent always has the skills for the **installed** version of each package (spec §6.6).
```

Then sections, each short:
- **When it runs:** the record (`packageSkillsRecordPath`, `PackageSkillsRecord`), what "same inputs" means, the retry rule (`retryFailure`: `run` yes, `detect` no) and why (offline, about 41 s per try).
- **For which agents:** `setUpAgents`, the folders, `integrations.agents`; sync never creates the folders.
- **The command:** `dartCommand`, the pinned `packageSkillsVersion`, why `--all` (no terminal installs nothing), the 120 s limit.
- **Judging a run:** `packageSkillsFailure` and the real outputs it was built from (exit 0 on a bad agent and on a failed internal `pub get`; the `Installed N skill(s) for <agent>` line; Codex printed as `generic`).
- **Two syncs at once:** the zero-timeout `KnowledgeLock` on `.dart_tool/appstein/`, re-checking the record inside the lock.
- **What it writes outside `.appstein/`:** the agent skill folders, `.config/dart_skills/skills_config.json` (committed, spec §6.2's table), `.dart_tool/skills/`, and package:skills' own `global_config.json` in the user's app-data folder; the osv.dev call.
- **What sync prints:** the lines from `formatPackageSkills`.
- **Tests:** `test/skills/package_skills_test.dart`, `test/knowledge/knowledge_sync_package_skills_test.dart`, `test/integration/package_skills_real_test.dart` (needs pub.dev), and the `package skills` group in `packages/appstein_cli/test/sync_command_test.dart`.

Every Dart snippet in the page must analyze (the docs job checks them); prefer naming functions with links over code blocks. Every repo path mentioned must exist.

- [ ] **Step 2: Update the other pages**

- `README.md`: a row `| [package-skills](package-skills.md) | How \`appstein sync\` runs package:skills when dependencies change, for the agents set up in the project |`.
- `cli.md`: the `sync` report section lists the package skills line and its three forms, and that a current `--detect` can print it after its one line.
- `incremental-sync.md`: `detect` runs package skills too (without retrying a failure); the timing step list gains `package skills`.

- [ ] **Step 3: Generate and check**

Run, from the repo root:
- `fvm dart run tool/gen_docs.dart`
- `fvm dart run tool/check_guide.dart --since main`
- `cd packages/appstein_engine && fvm dart doc --dry-run` (and the same in `packages/appstein_cli`)
Expected: gen_docs reports what it wrote; check_guide prints no problems; `dart doc` prints no warnings.

- [ ] **Step 4: Commit**

```bash
LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test
git add docs/guide
git commit -m "docs(guide): package skills page; cli and incremental-sync updates"
```

- [ ] **Step 5: Update the knowledge graph**

Run `tool/check_graph.py` with graphify's Python, then `/graphify . --update` until it reports nothing (see `docs/guide/docs-tooling.md` and the graph-update runbook). This step writes no repo file other than through graphify.

---

## Finishing (after the final review)

These follow the repo's per-slice flow and are not a task for an implementer:
1. Run every suite from inside each package folder, plus the root `fvm dart test test`, and the integration tests.
2. Open the PR; once it is open, mark 1b.8 done in `docs/superpowers/progress.yaml` with its `pr` and `finished`, set the next slice `next`, add this plan's notes from execution, run `fvm dart run tool/gen_docs.dart`, read back the rendered progress section, and commit.
3. Draft the upstream issue for dart-lang/ai ("let `get` skip writing global_config.json") for the owner to post or not. Nothing is posted by an agent.

## Notes from execution

Built natively (the owner chose "native") on `slice-1b8`, 2026-10-03, then one final review on Opus. PR #3.

**Commits:** `a6b4eb2` spec §6.6/§6.2/§15; `8aea539` this plan; `e6fcbef` Task 1; `739d932` Task 2; `5ba71fd` Task 3; `6e84ab8` Task 4; `ca36441` Task 5; `c2fb361` Task 6 (guide); `5653962` final-review fix; then the owner-approved §6.6 wording fix.

**Owner decisions (brainstorming):**
1. Run package:skills and document its global file, rather than only telling the user, or redirecting `APPDATA`/`HOME` (fragile).
2. Only configured agents that are already set up in the project; sync never creates agent folders.
3. After the review: the §6.6 wording says the global file is rewritten on every run that installs anything, and that `--all` also installs from configured git repositories.

**Rulings:**
- Task 1: two extra test cases (agent order in `sameInputs`, a `toText` round trip). Cost if wrong: none.
- Task 2: `return _failed(...)` inside the `try` is awaited (the analyzer's `unawaited_return_in_try_block`); otherwise `finally` released the lock before the failure record was saved. No failing test first: the ordering isn't observable with the fake runner.
- Task 6: the graph update moved to after the PR's notes commit, since those change docs again.

**The final review caught (fixed test-first):** when no dependency ships skills, which is most apps, package:skills prints only `No skills found.` and exits 0, before installing (`get_skills.dart:184-190`). The check expected an `Installed N skill(s)` line per agent, so every full sync of such an app with an agent set up would have warned and rerun package:skills (about 2.6 s). The probe's `Installed 0` lines came from the removed-package case, read wrongly as "nothing ships skills". The integration test now also runs a plain app. The review also corrected three guide claims: package:skills' own `pub get` uses the PATH `flutter` or `dart`; the global file isn't rewritten on a `No skills found.` run; `get --all` also installs from configured git repositories.

**Lesson:** a probe that captures real output must cover the common case (here, an app with nothing to install), not only the cases the design worries about. Reading each captured output's preconditions would have shown that `Installed 0` came from pruning.

**Deferred minors:**
- The "no agents" and "packages not fetched" outcomes are decided before the lock, so two syncs at the same moment can both print that line.
- `detect`'s current branch passes `packagesReady: true`, which is right only because freshness counts stale packages as not current; it could pass `prepared.packages.fresh`.

**Carried to later slices:**
- The upstream issue draft (conditional final save of `global_config.json`, or a flag to skip it) is for the owner to post.
- The min-sdk CI job doesn't run `package_skills_real_test`, so "`dart run pkg@version` works on Flutter 3.44" is from Dart's changelog, not tested here.
