import 'dart:convert';
import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein sync [--detect]`: regenerates the knowledge Appstein keeps in
/// `.appstein/` (spec §5.3, §5.4). With `--detect`, only when something it
/// reads changed. It writes the platform layer (`sdk.json`,
/// `toolchain.json`), the version delta (`delta.md`) and the project map
/// (`map/*.json`, `native.json` included), then `state.json`.
final class SyncCommand extends Command<int> {
  /// Creates the command.
  SyncCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser.addFlag(
      'detect',
      negatable: false,
      help:
          'Rebuild only when something the knowledge reads changed, found by '
          'content hash (the after-edit hook).',
    );
  }

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
      final sync = KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
        baseline: config.delta.baseline,
      );
      final report = argResults!['detect'] as bool
          ? await sync.detect(projectRoot)
          : await sync.run(projectRoot);
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
/// it, what native config found for each platform, the notes coverage, and
/// any toolchain fallback. A `--detect` that found nothing changed is one
/// line; otherwise it says what changed or why it rebuilt, and any
/// analyzer-cache problem.
String formatSyncReport(SyncReport report) {
  final sdk = report.sdk;
  if (report.current) {
    return 'Knowledge is current for Flutter ${sdk.flutterVersion} '
        '(Dart ${sdk.dartVersion}, ${sdk.channel} channel): nothing it reads '
        'changed since the last sync.\n';
  }
  final width = report.files.keys.map((path) => path.length).fold(0, max);
  final buffer = StringBuffer()
    ..writeln(
      'Synced .appstein/ for Flutter ${sdk.flutterVersion} '
      '(Dart ${sdk.dartVersion}, ${sdk.channel} channel).',
    );
  if (report.changed.isNotEmpty) {
    buffer.writeln('Changed since the last sync: ${_names(report.changed)}.');
  } else if (report.rebuiltBecause case [final first, ...final rest]) {
    buffer.writeln(
      'Rebuilt because $first'
      '${rest.isEmpty ? '' : ' (and ${rest.length} more)'}.',
    );
  }
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
  if (report.native case final native?) {
    if (native.sections.isNotEmpty) {
      buffer.writeln(
        'Native config: '
        '${[for (final MapEntry(:key, :value) in native.sections.entries) '$key $value'].join('; ')}.',
      );
    }
    // An Appstein bug the user can't fix: ask for a report, with the whole
    // error (native.json names only its type).
    for (final MapEntry(key: section, value: error) in native.errors.entries) {
      buffer.writeln(
        'Native config ($section): missing because of an internal error in '
        'Appstein. Please report it, with this error:',
      );
      for (final line in const LineSplitter().convert(error)) {
        buffer.writeln('  $line');
      }
    }
  }
  if (report.analyzerCache case final cache?) {
    if (cache.damage case final why?) {
      buffer.writeln(
        'The analyzer cache could not be used ($why), so this sync analyzed '
        'without it.',
      );
    }
    if (cache.retried case final error?) {
      // When the save failed, the old cache is still there.
      final replaced = cache.saveError == null
          ? ' and the cache was replaced'
          : '';
      buffer.writeln(
        'The analyzer failed while reading its cache ($error), so the '
        'analysis ran again without it$replaced.',
      );
    }
    if (cache.saveError case final why?) {
      buffer.writeln(
        'warning: the analyzer cache could not be saved ($why); the next '
        'sync will be slower.',
      );
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

/// [names] (input names) for one line: the first five, without the
/// `project:` prefix, then how many more.
String _names(List<String> names) {
  const prefix = 'project:';
  final shown = [
    for (final name in names.take(5))
      name.startsWith(prefix) ? name.substring(prefix.length) : name,
  ];
  final rest = names.length - shown.length;
  return '${shown.join(', ')}${rest > 0 ? ' and $rest more' : ''}';
}
