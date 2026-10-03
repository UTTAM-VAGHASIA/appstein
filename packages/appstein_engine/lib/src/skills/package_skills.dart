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
