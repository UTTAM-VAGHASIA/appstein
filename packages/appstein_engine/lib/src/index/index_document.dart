import 'dart:convert';
import 'dart:math';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../knowledge/markdown_front_matter.dart';
import '../notes/flutter_minor.dart';
import 'index_sources.dart';

/// Where `INDEX.md` lives inside `.appstein/` (spec §6.2).
const indexPath = 'INDEX.md';

/// The most bytes `INDEX.md` may have, front matter included: 1,500
/// tokens, counted as UTF-8 bytes ÷ 3 (spec §6.3).
const indexByteBudget = 4500;

/// Every MCP tool `INDEX.md` can name (spec §6.3, §8).
const indexTools = {
  'where_is',
  'feature',
  'route',
  'toolchain',
  'what_changed',
  'verify',
  'package_check',
  'decisions',
  'memory_read',
};

/// What `INDEX.md` is built from (spec §6.3).
final class IndexInputs {
  /// Creates the inputs.
  const IndexInputs({
    required this.projectName,
    required this.sdk,
    required this.appsteinVersion,
    required this.newestNotes,
    required this.stackPack,
    required this.platforms,
    required this.appIds,
    required this.features,
    this.featuresMissing,
    required this.layers,
    required this.notes,
    required this.apiCounts,
    this.decisions = const [],
    this.decisionsError,
    this.currentWork = const [],
    this.currentWorkError,
    this.tools = indexTools,
  });

  /// The name in `pubspec.yaml`; null when it can't be read.
  final String? projectName;

  /// The SDK facts, with the notes coverage.
  final SdkInfo sdk;

  /// The version of the running Appstein.
  final String appsteinVersion;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// The stack pack's id, or null without one.
  final String? stackPack;

  /// The platform folders that exist.
  final List<String> platforms;

  /// The app and bundle id lines (`appIdLines`).
  final List<String> appIds;

  /// The features table's rows, ordered (`indexFeatures`); null when there
  /// is no `features.json`, with the reason in [featuresMissing].
  final List<IndexFeature>? features;

  /// Why [features] is null, in words that follow "Not available: ".
  final String? featuresMissing;

  /// The stack pack's layer tags and their globs, in match order; null
  /// without a stack pack.
  final Map<String, List<String>>? layers;

  /// The curated notes to list, most important first (`delta.md`'s order,
  /// without the notes that need a newer language version).
  final List<CuratedNote> notes;

  /// How many APIs `delta.md` lists; null when it has no API lists.
  final DeltaCounts? apiCounts;

  /// The decisions to list, in file-name order.
  final List<IndexDecision> decisions;

  /// Why `.appstein/decisions/` couldn't be read; null otherwise.
  final String? decisionsError;

  /// The lines of `memory/current.md`.
  final List<String> currentWork;

  /// Why `memory/current.md` couldn't be read; null otherwise.
  final String? currentWorkError;

  /// The MCP tools this Appstein offers. `INDEX.md` names a tool only when
  /// it is here (spec §6.3); a pointer to a missing tool names the file
  /// instead. `sync` passes the server's own list.
  final Set<String> tools;
}

/// How many bytes `INDEX.md`'s text may have when it is written with
/// [meta]: [indexByteBudget] minus the front matter. Every `generatedAt`
/// has the same length, so any time will do in [meta].
int indexBodyBudget(KnowledgeMeta meta) =>
    indexByteBudget -
    (utf8.encode(markdownWithFrontMatter('', meta)).length - 1);

/// The text of `INDEX.md` without its front matter (spec §6.3), at most
/// [byteBudget] UTF-8 bytes when that can be done.
///
/// When the full text is longer, it cuts one item at a time in §6.3's
/// order: version notes down to 5, then current work, then decisions
/// (keeping the newest), then features down to 5 rows. The generic notes go
/// first because the project's own decisions and current work exist nowhere
/// else in view; the other notes are one call away in `what_changed()`. Each
/// cut leaves a pointer to the MCP tool that holds the rest. Only if the text
/// still doesn't fit do features, then notes, go below 5. Project, rules,
/// where things live and freshness are never cut.
String renderIndex(IndexInputs inputs, {required int byteBudget}) {
  var limits = _Limits.start(inputs);
  var text = _render(inputs, limits);
  while (utf8.encode(text).length > byteBudget) {
    final next = limits.cut();
    if (next == null) break;
    limits = next;
    text = _render(inputs, limits);
  }
  return text;
}

/// How many items of each section that can be cut are shown.
final class _Limits {
  const _Limits({
    required this.currentWork,
    required this.decisions,
    required this.features,
    required this.notes,
  });

  _Limits.start(IndexInputs inputs)
    : currentWork = min(10, inputs.currentWork.length),
      decisions = inputs.decisions.length,
      features = min(15, inputs.features?.length ?? 0),
      notes = min(10, inputs.notes.length);

  final int currentWork;
  final int decisions;
  final int features;
  final int notes;

  /// One item fewer, in §6.3's order: notes to 5, current work, decisions,
  /// features to 5. The generic notes go first because the project's own
  /// decisions and current work exist nowhere else in view; the other notes
  /// are one call away in `what_changed()`. Null when nothing is left to cut.
  _Limits? cut() {
    if (notes > 5) return _with(notes: notes - 1);
    if (currentWork > 0) return _with(currentWork: currentWork - 1);
    if (decisions > 0) return _with(decisions: decisions - 1);
    if (features > 5) return _with(features: features - 1);
    // Past §6.3's floors only when even they don't fit (D8).
    if (features > 0) return _with(features: features - 1);
    if (notes > 0) return _with(notes: notes - 1);
    return null;
  }

  _Limits _with({
    int? currentWork,
    int? decisions,
    int? features,
    int? notes,
  }) => _Limits(
    currentWork: currentWork ?? this.currentWork,
    decisions: decisions ?? this.decisions,
    features: features ?? this.features,
    notes: notes ?? this.notes,
  );
}

/// The rules that matter most. A rule names a tool only when [tools] has
/// it: without `verify` its rule is left out, and without `package_check`
/// the dependency rule doesn't name it.
List<String> _rules(Set<String> tools) => [
  "- Ask Appstein's MCP tools (`where_is()`, `feature()`, `route()`) before "
      'searching the code.',
  if (tools.contains('verify'))
    '- Run `verify()` before you say a task is done.',
  '- Never upgrade native toolchain versions (Gradle, the Android Gradle '
      'Plugin, Kotlin, the NDK, SDK levels, the iOS deployment target) '
      'yourself; ask `toolchain()`.',
  '- Dependencies: pure Dart for small helpers; '
      '${tools.contains('package_check') ? 'a package that passes '
                '`package_check()`' : 'a well-maintained package'} '
      'for platform features; Pigeon with platform channels for small '
      'native code.',
];

String _render(IndexInputs inputs, _Limits limits) {
  final out = StringBuffer();
  void heading(String title) => out
    ..writeln()
    ..writeln('## $title')
    ..writeln();

  out
    ..writeln('# ${inputs.projectName ?? 'This project'}')
    ..writeln()
    ..writeln(
      "Appstein's summary of this project, always in view. `appstein sync` "
      "writes it; don't edit it. Everything else is in `.appstein/` and "
      "Appstein's MCP tools.",
    );
  heading('Project');
  _project(out, inputs);
  heading('Rules');
  for (final rule in _rules(inputs.tools)) {
    out.writeln(rule);
  }
  heading('Features');
  _features(out, inputs, limits.features);
  heading('Where things live');
  _layers(out, inputs.layers);
  heading('Version notes');
  _notes(out, inputs, limits.notes);
  heading('Decisions');
  _decisions(out, inputs, limits.decisions);
  heading('Current work');
  _currentWork(out, inputs, limits.currentWork);
  heading('Freshness');
  out.writeln(_freshness(inputs));
  return out.toString();
}

void _project(StringBuffer out, IndexInputs inputs) {
  final sdk = inputs.sdk;
  final stack = inputs.stackPack;
  out
    ..writeln(
      '- Flutter ${sdk.flutterVersion} (${sdk.channel} channel), Dart '
      '${sdk.dartVersion}, language version '
      '${sdk.languageVersion ?? 'unknown'}',
    )
    ..writeln('- Stack pack: ${stack == null ? 'none' : '`$stack`'}')
    ..writeln(
      '- Platforms: '
      '${inputs.platforms.isEmpty ? 'none found' : inputs.platforms.join(', ')}',
    );
  for (final line in inputs.appIds) {
    out.writeln('- $line');
  }
}

void _features(StringBuffer out, IndexInputs inputs, int shown) {
  final features = inputs.features;
  if (features == null) {
    out.writeln(
      _sentence(
        'Not available: ${inputs.featuresMissing ?? 'no reason was given'}',
      ),
    );
    return;
  }
  if (features.isEmpty) {
    out.writeln('None found.');
    return;
  }
  if (shown > 0) {
    out
      ..writeln('| Feature | Screens | Main files |')
      ..writeln('|---|---|---|');
    for (final feature in features.take(shown)) {
      final folder = '`${_cell(feature.folder)}/`';
      final files = [
        for (final file in feature.mainFiles.take(2)) _cell(file),
        if (feature.mainFiles.length > 2) '…',
      ];
      out.writeln(
        '| `${_cell(feature.name)}` | ${feature.screens} | '
        '${files.isEmpty ? folder : '$folder: ${files.join(', ')}'} |',
      );
    }
  }
  final hidden = features.length - shown;
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln('…and $hidden more; ask `feature()`.');
  }
}

void _layers(StringBuffer out, Map<String, List<String>>? layers) {
  if (layers == null || layers.isEmpty) {
    out.writeln('No stack pack, so no layers.');
    return;
  }
  for (final MapEntry(key: tag, value: globs) in layers.entries) {
    out.writeln(
      '- `$tag`: ${[for (final glob in globs) '`$glob`'].join(', ')}',
    );
  }
}

void _notes(StringBuffer out, IndexInputs inputs, int shown) {
  final notes = inputs.notes;
  if (notes.isEmpty) {
    out.writeln('No curated notes for this SDK.');
  } else {
    for (final note in notes.take(shown)) {
      out.writeln(
        '- **${note.id}** (priority ${note.priority}): '
        '${_oneLine(note.summary)}',
      );
    }
    final hidden = notes.length - shown;
    if (hidden > 0) {
      if (shown > 0) out.writeln();
      out.writeln('…and ${_count(hidden, 'more note')}; ask `what_changed()`.');
    }
  }
  final counts = inputs.apiCounts;
  out
    ..writeln()
    ..writeln(
      counts == null
          ? '`platform/delta.md` has no API lists this time; it says why. '
                'Ask `what_changed()`.'
          : '`platform/delta.md` also lists '
                '${_count(counts.deprecated, 'deprecated API')}, '
                '${_count(counts.removed, 'removed API')}, '
                '${_count(counts.changed, 'changed API')} and '
                '${_count(counts.moved, 'moved library', 'moved libraries')}; '
                'ask `what_changed()`.',
    );
}

void _decisions(StringBuffer out, IndexInputs inputs, int shown) {
  if (inputs.decisionsError case final error?) {
    out.writeln(_sentence("Couldn't read `.appstein/decisions/`: $error"));
    return;
  }
  final decisions = inputs.decisions;
  if (decisions.isEmpty) {
    out.writeln('None recorded yet.');
    return;
  }
  // The newest decisions are the last; they are the ones kept.
  final hidden = decisions.length - shown;
  for (final decision in decisions.skip(hidden)) {
    out.writeln(_decisionLine(decision));
  }
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln(
      '…and ${_count(hidden, 'older decision')}'
      '${inputs.tools.contains('decisions') ? '; ask `decisions()`.' : ' in `decisions/`.'}',
    );
  }
}

String _decisionLine(IndexDecision decision) {
  // Angle brackets keep a file name with spaces a valid link.
  final link = '[${decision.file}](<decisions/${decision.file}>)';
  if (decision.problem case final problem?) {
    return '- $link: unreadable (${_withoutFullStop(problem)}).';
  }
  final id = decision.id == null ? '' : '${decision.id} ';
  return '- $id${decision.title} (${decision.status}): $link';
}

void _currentWork(StringBuffer out, IndexInputs inputs, int shown) {
  if (inputs.currentWorkError case final error?) {
    out.writeln(_sentence("Couldn't read `memory/current.md`: $error"));
    return;
  }
  final lines = inputs.currentWork;
  if (lines.isEmpty) {
    out.writeln('None recorded yet.');
    return;
  }
  // A quote, so a heading in current.md can't become a section here.
  for (final line in lines.take(shown)) {
    out.writeln(line.isEmpty ? '>' : '> $line');
  }
  final hidden = lines.length - shown;
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln(
      '…and ${_count(hidden, 'more line')}'
      '${inputs.tools.contains('memory_read') ? '; ask `memory_read()`.' : ' in `memory/current.md`.'}',
    );
  }
}

String _freshness(IndexInputs inputs) {
  final sdk = inputs.sdk;
  final notes = sdk.notesCoverage == NotesCoverage.complete
      ? 'Curated notes cover Flutter ${inputs.newestNotes} and earlier.'
      : 'Curated notes may be incomplete for Flutter '
            '${_minorText(sdk.flutterVersion)}: the newest notes are for '
            '${inputs.newestNotes}.';
  return 'Synced by Appstein ${inputs.appsteinVersion} for Flutter '
      '${sdk.flutterVersion}. $notes';
}

String _minorText(String version) {
  final minor = flutterMinorOf(version);
  return minor == null ? version : '${minor.major}.${minor.minor}';
}

/// [n] and the noun, singular for 1.
String _count(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : plural ?? '${singular}s'}';

/// [text] safe inside a Markdown table cell.
String _cell(String text) => text.replaceAll('|', r'\|');

/// [text] with each run of white space as one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text] on one line, ending in a full stop.
String _sentence(String text) {
  final line = _oneLine(text);
  return line.endsWith('.') || line.endsWith('!') || line.endsWith('?')
      ? line
      : '$line.';
}

/// [text] on one line, without a final full stop.
String _withoutFullStop(String text) {
  final line = _oneLine(text);
  return line.endsWith('.') ? line.substring(0, line.length - 1) : line;
}
