import 'package:appstein_protocol/appstein_protocol.dart';

import '../decisions/decision_store.dart';

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
/// map, the SDK facts, the decisions and the team's own notes. A page
/// source reads nothing else, so the same knowledge always gives the same
/// pages.
final class DocsKnowledge {
  /// Creates the knowledge.
  const DocsKnowledge({
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
}
