import 'dart:convert';
import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein sync`: regenerates the knowledge Appstein keeps in
/// `.appstein/` (spec §5.3). It writes the platform layer (`sdk.json`,
/// `toolchain.json`), the version delta (`delta.md`) and the project map
/// (`map/*.json`), then `state.json`.
final class SyncCommand extends Command<int> {
  /// Creates the command.
  SyncCommand({
    required this.out,
    required this.err,
    required this.environment,
  });

  /// Where the report goes.
  final StringSink out;

  /// Where problems go.
  final StringSink err;

  /// The machine, used to find the project and the Flutter SDK.
  final HostEnvironment environment;

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Regenerate the knowledge Appstein keeps in .appstein/.';

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      err
        ..writeln(
          'appstein sync needs a Flutter project, but there is no '
          'pubspec.yaml in ${environment.workingDirectory} or any folder '
          'above it.',
        )
        ..writeln('Run it inside the project, or pass --project <path>.');
      return ExitCodes.appsteinFailed;
    }
    final AppsteinConfig config;
    try {
      config = loadConfig(projectRoot) ?? const AppsteinConfig();
    } on ConfigException catch (error) {
      err
        ..writeln(error)
        ..writeln('Fix appstein.yaml, then run `appstein sync` again.');
      return ExitCodes.appsteinFailed;
    }
    try {
      final report = await KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
        baseline: config.delta.baseline,
      ).run(projectRoot);
      out.write(formatSyncReport(report));
      return ExitCodes.ok;
    } on SyncException catch (error) {
      err
        ..writeln(error.problem)
        ..writeln(error.fixHint);
      return ExitCodes.appsteinFailed;
    } on KnowledgeLockTimeout catch (error) {
      err.writeln(error);
      return ExitCodes.appsteinFailed;
    } on KnowledgeWriteException catch (error) {
      err.writeln(error);
      // A write that gave up on an open file already says what to do.
      if (!error.toString().contains('`appstein sync`')) {
        err.writeln(
          'Check that the project folder is writable and that .appstein is a '
          'folder, then run `appstein sync` again.',
        );
      }
      return ExitCodes.appsteinFailed;
    }
  }
}

/// The text `appstein sync` prints for [report]: the SDK, each file written
/// or unchanged, what happened to the project's packages (fetched, or why
/// they could not be), the project map's skip reason and what to do about
/// it, the notes coverage, and any toolchain fallback.
String formatSyncReport(SyncReport report) {
  final sdk = report.sdk;
  final width = report.files.keys.map((path) => path.length).fold(0, max);
  final buffer = StringBuffer()
    ..writeln(
      'Synced .appstein/ for Flutter ${sdk.flutterVersion} '
      '(Dart ${sdk.dartVersion}, ${sdk.channel} channel).',
    );
  for (final MapEntry(key: path, value: written) in report.files.entries) {
    buffer.writeln(
      '  ${path.padRight(width)}  ${written ? 'written' : 'unchanged'}',
    );
  }
  final map = report.map;
  if (map != null) {
    switch (map.packages) {
      case PackagesAction.fetched:
        buffer.writeln(
          'Fetched the packages with `flutter pub get`, because '
          '${map.packagesReason}.',
        );
      case PackagesAction.fetchFailed:
        buffer.writeln('Could not fetch the packages:');
        for (final line in const LineSplitter().convert(map.packagesReason)) {
          buffer.writeln('  $line');
        }
      case PackagesAction.upToDate:
        break;
    }
    if (map.skipped case final skipped?) {
      final reason = skipped.endsWith('.')
          ? skipped.substring(0, skipped.length - 1)
          : skipped;
      buffer
        ..writeln('Project map skipped: $reason.')
        ..writeln(
          map.packages == PackagesAction.fetchFailed
              ? 'Run `flutter pub get` in the project to see the whole error, '
                    'then `appstein sync` again.'
              : 'Fix that, then run `appstein sync` again.',
        );
    }
  }
  if (map?.deltaError case final error?) {
    // An Appstein bug the user can't fix: ask for a report, with the whole
    // error (delta.md names only its type).
    buffer.writeln(
      'Version delta: deprecated and removed APIs are missing because of an '
      'internal error in Appstein. Please report it, with this error:',
    );
    for (final line in const LineSplitter().convert(error)) {
      buffer.writeln('  $line');
    }
  }
  // Coverage is "complete" only when known; unknown counts as partial, the
  // same as in delta.md.
  if (sdk.notesCoverage != NotesCoverage.complete) {
    final minor = flutterMinorOf(sdk.flutterVersion);
    final version = minor == null
        ? sdk.flutterVersion
        : '${minor.major}.${minor.minor}';
    buffer.writeln(
      'Curated notes may be incomplete for Flutter $version: the newest '
      'notes are for ${report.newestNotes}.',
    );
  } else {
    buffer.writeln(
      'Curated notes cover Flutter ${report.newestNotes} and earlier.',
    );
  }
  for (final fallback in report.fallbacks) {
    buffer.writeln('toolchain.fallback (info): $fallback');
  }
  return buffer.toString();
}
