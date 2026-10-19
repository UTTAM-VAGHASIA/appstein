import '../json_fields.dart';

/// How serious the analyzer says a diagnostic is.
enum DiagnosticLevel {
  /// The code doesn't compile, or breaks a rule the project made an error.
  error,

  /// An analyzer warning.
  warning,

  /// An info-level diagnostic: most lints, and hints.
  info,
}

/// One diagnostic the analyzer reports for a file of the project.
final class CodeDiagnostic {
  /// Creates a diagnostic.
  const CodeDiagnostic({
    required this.file,
    required this.line,
    required this.code,
    required this.message,
    required this.level,
    this.correction,
    this.offset,
  });

  /// Reads a diagnostic written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory CodeDiagnostic.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return CodeDiagnostic(
      file: json.string('file'),
      line: json.integer('line'),
      code: json.string('code'),
      message: json.string('message'),
      level: _level(json, 'level'),
      correction: json.optionalString('correction'),
      offset: json.optionalInteger('offset'),
    );
  }

  /// Where it starts in the file, in UTF-16 code units from the file's
  /// start: what the engine's `CodeAnalysis.canDartFix` asks the server
  /// about. The analysis server always gives it; null only from a test's
  /// stand-in.
  final int? offset;

  /// The file it is in, from the project root, with `/` on every system.
  final String file;

  /// The 1-based line it starts on.
  final int line;

  /// The analyzer's own code, such as `unused_import`.
  final String code;

  /// The analyzer's message.
  final String message;

  /// How serious the analyzer says it is, after the project's
  /// `analysis_options.yaml`.
  final DiagnosticLevel level;

  /// What the analyzer suggests doing about it; null when it suggests
  /// nothing.
  final String? correction;

  /// The diagnostic as JSON, as the analysis host sends it.
  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'code': code,
    'message': message,
    'level': level.name,
    'correction': ?correction,
    'offset': ?offset,
  };
}

/// What a message that can't be read is named after in its error.
const _source = 'an answer of the analysis host';

DiagnosticLevel _level(JsonFields json, String key) {
  final name = json.string(key);
  for (final level in DiagnosticLevel.values) {
    if (level.name == name) return level;
  }
  throw FormatException('${json.file}: "$key" must be a diagnostic level.');
}

/// One reading of what the analyzer says about a project: everything in it
/// is from the same moment.
final class CodeReading {
  /// Creates a reading.
  const CodeReading({
    this.diagnostics = const [],
    this.pluginFailures = const [],
    this.notices = const [],
    this.analyzedFiles = const [],
    this.unreadableFiles = const {},
  });

  /// Reads a reading written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory CodeReading.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return CodeReading(
      diagnostics: [
        for (final item in json.objects('diagnostics'))
          CodeDiagnostic.fromJson(item.json),
      ],
      pluginFailures: json.strings('pluginFailures'),
      notices: json.strings('notices'),
      analyzedFiles: json.strings('analyzedFiles'),
      unreadableFiles: json.stringMap('unreadableFiles'),
    );
  }

  /// Each Dart file of the project the analysis covers that could not be
  /// opened and read when this reading was taken (on Windows, one another
  /// program holds locked), by its path from the project root with `/`,
  /// with why. The analysis server reads such a file as empty and reports no
  /// diagnostic for it, so nothing in it was checked: a check must never
  /// take it for clean (`dart.unreadable`).
  final Map<String, String> unreadableFiles;

  /// What the person or agent who runs `verify` must be told that is no
  /// finding about the project, one plain line each: a process that may be
  /// an analysis server Appstein started and could not show to be its own,
  /// so it did not end it, with the command to end it by hand; and, for a
  /// session whose Appstein is older than the project's analysis host, that
  /// it should be restarted for fast answers. `runVerify` passes them on in
  /// the result.
  final List<String> notices;

  /// Every diagnostic `dart analyze` would show for the project, in file
  /// and line order. That includes the files the analyzer reads that aren't
  /// Dart (`analysis_options.yaml`, `pubspec.yaml`), and leaves out the
  /// `TODO` comments the analyzer notes at info level, which `dart analyze`
  /// hides too. A `TODO` the project raised to a warning or an error in
  /// `analysis_options.yaml` is included.
  final List<CodeDiagnostic> diagnostics;

  /// What the analysis server said about each analyzer plugin it could not
  /// load or run, one message each, on one line. While this isn't empty,
  /// [diagnostics] lacks that plugin's rules: "no diagnostics" then doesn't
  /// mean "no problems".
  final List<String> pluginFailures;

  /// Every file of the project the analyzer analyzed for this reading, with
  /// or without a diagnostic, from the project root, with `/` on every
  /// system, sorted. It includes a part file whose name doesn't end in
  /// `.dart` and the files that aren't Dart (`analysis_options.yaml`,
  /// `pubspec.yaml`), and leaves out what `analysis_options.yaml` excludes.
  ///
  /// A check that reads source files itself reads these, so it covers
  /// exactly what the analyzer covered.
  final List<String> analyzedFiles;

  /// The reading as JSON, as the analysis host sends it.
  Map<String, Object?> toJson() => {
    'diagnostics': [for (final item in diagnostics) item.toJson()],
    'pluginFailures': pluginFailures,
    'notices': notices,
    'analyzedFiles': analyzedFiles,
    'unreadableFiles': unreadableFiles,
  };
}

/// What the engine's `CodeAnalysis.applyFixesAndFormat` did to the
/// project's files.
final class AppliedChanges {
  /// Creates the outcome.
  const AppliedChanges({this.written = const [], this.leftAlone = const {}});

  /// Reads an outcome written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AppliedChanges.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return AppliedChanges(
      written: json.strings('written'),
      leftAlone: json.stringMap('leftAlone'),
    );
  }

  /// Each file it rewrote, from the project root with `/`, sorted.
  final List<String> written;

  /// Each file it would have rewritten and left as it was, from the project
  /// root with `/` (or as the server named it, when outside), with why in
  /// words that follow "left as it was: ".
  final Map<String, String> leftAlone;

  /// One line for each of [leftAlone], for the run's notices: they are no
  /// finding, but the reader must know the file was not rewritten.
  List<String> get notices => [
    for (final MapEntry(key: file, value: why) in leftAlone.entries)
      'Applying fixes and formatting left `$file` as it was: $why. What it '
          'needs is still reported.',
  ];

  /// The outcome as JSON, as the analysis host sends it.
  Map<String, Object?> toJson() => {'written': written, 'leftAlone': leftAlone};
}

/// What the engine's `CodeAnalysis.pendingFixes` found: the fixes `dart
/// fix` would apply, by file and code.
final class PendingFixes {
  /// Creates the answer.
  const PendingFixes({
    this.counts = const {},
    this.passes = 0,
    this.unfinished,
    this.notCounted = const [],
  });

  /// Reads an answer written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory PendingFixes.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return PendingFixes(
      counts: {
        for (final MapEntry(key: file, value: codes)
            in json.objectMap('counts').entries)
          file: {for (final code in codes.json.keys) code: codes.integer(code)},
      },
      passes: json.integer('passes'),
      unfinished: json.optionalString('unfinished'),
      notCounted: json.strings('notCounted'),
    );
  }

  /// The files the server had fixes for that are outside the project once
  /// links are followed (a link from the project to a file elsewhere), from
  /// the project root with `/`, sorted: their fixes are not in [counts], so
  /// the counts can be lower than `dart fix --dry-run`'s, which follows the
  /// link.
  final List<String> notCounted;

  /// One line for each of [notCounted], for the run's notices.
  List<String> get notices => [
    for (final file in notCounted)
      '`dart fix` would also fix `$file`, which is outside the project once '
          'links are followed; its fixes were not counted in '
          '`dart.fix_pending`, and `--apply` leaves it as it is.',
  ];

  /// How many fixes of each code `dart fix` would apply in each file: the
  /// file from the project root with `/`, then the diagnostic's code, then
  /// the count summed over the passes, as `dart fix --dry-run` sums them.
  final Map<String, Map<String, int>> counts;

  /// How many passes found fixes.
  final int passes;

  /// Why the passes stopped before one found no fix, in words that complete
  /// "the pending fixes were not all found: "; null when they finished. The
  /// [counts] are then those of the passes that ended, so they may be lower
  /// than `dart fix` would list.
  final String? unfinished;

  /// The answer as JSON, as the analysis host sends it.
  Map<String, Object?> toJson() => {
    'counts': counts,
    'passes': passes,
    'unfinished': ?unfinished,
    'notCounted': notCounted,
  };
}

/// What the engine's `CodeAnalysis.formatChanges` found out about the files
/// it was asked about. A file is in at most one of the two maps; one in
/// neither was not answered in time.
final class FormatAnswers {
  /// Creates the answers.
  const FormatAnswers({this.changed = const {}, this.refused = const {}});

  /// Reads answers written by [toJson]. Throws a [FormatException] when
  /// [map] isn't them.
  factory FormatAnswers.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    final changed = json.object('changed');
    return FormatAnswers(
      changed: {
        for (final file in changed.json.keys) file: changed.boolean(file),
      },
      refused: json.stringMap('refused'),
    );
  }

  /// The files that were answered: true when the formatter would change
  /// the file, false when it would not.
  final Map<String, bool> changed;

  /// The files the server could not answer for, with why in one line: it
  /// refused the question for that file, or the file changed (or could not be
  /// read again) while it was being answered, so the answer is not about the
  /// text the reading saw.
  final Map<String, String> refused;

  /// The answers as JSON, as the analysis host sends them.
  Map<String, Object?> toJson() => {'changed': changed, 'refused': refused};
}
