import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../decisions/decision_store.dart';
import '../knowledge/canonical_json.dart';
import '../knowledge/input_hash.dart';

/// A Markdown file in the docs folder that Appstein didn't generate (spec
/// §6.9): a team's own note. Appstein never touches it, and `README.md`
/// lists it.
final class TeamNote {
  /// Creates the note.
  const TeamNote({required this.path, required this.title});

  /// Its path inside the docs folder, with `/`.
  final String path;

  /// Its first `# ` heading, or its path when it has none.
  final String title;
}

/// Everything the human docs are rendered from (spec §6.9): the project
/// map, the SDK facts, the decisions and the team's own notes.
///
/// Pages never read it directly. Each page source gets a [view], which
/// records the parts it read, so a page's input hash covers exactly what the
/// page was rendered from.
final class DocsKnowledge {
  /// Creates the knowledge.
  DocsKnowledge({
    required this.docsPath,
    required this.projectName,
    required this.platforms,
    required this.stack,
    required this.sdk,
    required this.features,
    required this.symbols,
    required this.routes,
    required this.layers,
    required this.deps,
    required this.native,
    required this.decisions,
    this.teamNotes = const [],
  });

  /// The names of the parts a view can read, as [DocsView.read] and
  /// [digestOf] use them.
  static const partNames = [
    'projectName',
    'platforms',
    'stack',
    'sdk',
    'features',
    'symbols',
    'routes',
    'layers',
    'deps',
    'native',
    'decisions',
    'teamNotes',
  ];

  /// The docs folder from the project root, with `/`, such as `docs/app`.
  final String docsPath;

  /// The name in `pubspec.yaml`; null when it can't be read.
  final String? projectName;

  /// The platform folders the project has, such as `android`.
  final List<String> platforms;

  /// The stack pack's id, such as `official_mvvm`.
  final String stack;

  /// `platform/sdk.json`.
  final SdkInfo sdk;

  /// `map/features.json`.
  final FeaturesMap features;

  /// `map/symbols.json`.
  final SymbolsMap symbols;

  /// `map/routes.json`.
  final RoutesMap routes;

  /// `map/layers.json`.
  final LayersMap layers;

  /// `map/deps.json`.
  final DepsMap deps;

  /// `map/native.json`.
  final NativeConfig native;

  /// The decision records, read by the rules of spec §6.7.
  final DecisionSet decisions;

  /// The team's own notes in the docs folder, sorted by path.
  final List<TeamNote> teamNotes;

  final _digests = <String, String>{};

  /// A view of the knowledge that records which parts were read.
  DocsView view() => DocsView._(this);

  /// The SHA-256 of the part named [name] (one of [partNames]), as hex.
  ///
  /// A map file is hashed in canonical JSON without its `meta`, so the time
  /// it was generated never changes the hash. The decisions are hashed from
  /// each file's bytes and what is wrong with the set.
  ///
  /// Throws an [ArgumentError] for a name that isn't a part.
  String digestOf(String name) =>
      _digests[name] ??= sha256Hex(utf8.encode(canonicalJson(_content(name))));

  Object? _content(String name) => switch (name) {
    'projectName' => projectName,
    'platforms' => platforms,
    'stack' => stack,
    'sdk' => sdk.toJson(),
    'features' => features.toJson(),
    'symbols' => symbols.toJson(),
    'routes' => routes.toJson(),
    'layers' => layers.toJson(),
    'deps' => deps.toJson(),
    'native' => native.toJson(),
    'decisions' => {
      'files': {
        for (final MapEntry(:key, :value) in decisions.bytes.entries)
          key: sha256Hex(value),
      },
      'unreadable': {
        for (final file in decisions.unreadable) file.file: file.problem,
      },
      'duplicates': {
        for (final MapEntry(:key, :value) in decisions.duplicates.entries)
          '$key': value,
      },
      'problems': decisions.problems,
      'folderProblem': decisions.folderProblem,
    },
    'teamNotes' => [
      for (final note in teamNotes) {'path': note.path, 'title': note.title},
    ],
    _ => throw ArgumentError.value(name, 'name', 'is not a part'),
  };
}

/// One page source's view of the [DocsKnowledge]. Reading a part records
/// its name in [read]. [docsPath] isn't recorded: it is part of every
/// page's hash.
final class DocsView {
  DocsView._(this._knowledge);

  final DocsKnowledge _knowledge;
  final _read = <String>{};

  /// The names of the parts read so far.
  Set<String> get read => Set.unmodifiable(_read);

  T _note<T>(String name, T value) {
    _read.add(name);
    return value;
  }

  /// The docs folder from the project root, with `/`.
  String get docsPath => _knowledge.docsPath;

  /// The name in `pubspec.yaml`; null when it can't be read.
  String? get projectName => _note('projectName', _knowledge.projectName);

  /// The platform folders the project has.
  List<String> get platforms => _note('platforms', _knowledge.platforms);

  /// The stack pack's id.
  String get stack => _note('stack', _knowledge.stack);

  /// `platform/sdk.json`.
  SdkInfo get sdk => _note('sdk', _knowledge.sdk);

  /// `map/features.json`.
  FeaturesMap get features => _note('features', _knowledge.features);

  /// `map/symbols.json`.
  SymbolsMap get symbols => _note('symbols', _knowledge.symbols);

  /// `map/routes.json`.
  RoutesMap get routes => _note('routes', _knowledge.routes);

  /// `map/layers.json`.
  LayersMap get layers => _note('layers', _knowledge.layers);

  /// `map/deps.json`.
  DepsMap get deps => _note('deps', _knowledge.deps);

  /// `map/native.json`.
  NativeConfig get native => _note('native', _knowledge.native);

  /// The decision records.
  DecisionSet get decisions => _note('decisions', _knowledge.decisions);

  /// The team's own notes in the docs folder.
  List<TeamNote> get teamNotes => _note('teamNotes', _knowledge.teamNotes);
}
