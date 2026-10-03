import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../knowledge/canonical_json.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';

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
  bool folder(String name) => Directory(p.join(projectRoot, name)).existsSync();
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
      agents.join('\n') == other.agents.join('\n');

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
/// either printed `Installed N skill(s) for <agent> at …` for every agent
/// (N is 0 when it only pruned the skills of a removed package), or printed
/// the line `No skills found.`, which it does, and stops, when no
/// dependency ships skills. The reason quotes the first 10 lines of what it
/// printed.
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
  // Most apps: nothing to install, for any agent.
  if (lines.any((line) => line.trim() == 'No skills found.')) return null;
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

/// The `dart` command of the Flutter SDK at [flutterRoot]: `bin/dart`, or
/// `bin\dart.bat` on Windows. Never the `dart` on PATH, which may be another
/// SDK.
String dartCommand(String flutterRoot, HostOs os) =>
    p.join(flutterRoot, 'bin', os == HostOs.windows ? 'dart.bat' : 'dart');

/// What a package skills refresh did.
enum PackageSkillsOutcome {
  /// package:skills ran and installed the skills for
  /// [PackageSkillsReport.agents].
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
        // Awaited, so the record is saved before the lock is released.
        return await _failed(projectRoot, wanted, agents, failure);
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
