import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein sync`: regenerates the knowledge Appstein keeps in
/// `.appstein/` (spec §5.3). It writes the platform layer: `sdk.json`,
/// `toolchain.json` and `state.json`.
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
    try {
      final report = await PlatformSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
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
      return ExitCodes.appsteinFailed;
    }
  }
}

/// The text `appstein sync` prints for [report]: the SDK, each file written
/// or unchanged, the notes coverage, and any toolchain fallback.
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
  if (sdk.notesCoverage == NotesCoverage.partial) {
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
