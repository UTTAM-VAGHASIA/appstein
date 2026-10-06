import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// A small app's knowledge for page tests: one feature (`booking`) with a
/// screen, a view model, a repository and a service. Each part can be
/// replaced.
DocsKnowledge sampleKnowledge({
  String docsPath = 'docs/app',
  String? projectName = 'sample_app',
  List<String> platforms = const ['android', 'ios'],
  String stack = 'official_mvvm',
  SdkInfo? sdk,
  FeaturesMap? features,
  SymbolsMap? symbols,
  RoutesMap? routes,
  LayersMap? layers,
  DepsMap? deps,
  NativeConfig? native,
  DecisionSet decisions = const DecisionSet(),
  List<TeamNote> teamNotes = const [],
}) => DocsKnowledge(
  docsPath: docsPath,
  projectName: projectName,
  platforms: platforms,
  stack: stack,
  sdk:
      sdk ??
      const SdkInfo(
        flutterVersion: '3.47.5',
        dartVersion: '3.13.4',
        channel: 'stable',
        languageVersion: '3.12',
      ),
  features: features ?? sampleFeatures,
  symbols: symbols ?? sampleSymbols,
  routes: routes ?? sampleRoutes,
  layers: layers ?? const LayersMap(files: {}, violations: []),
  deps: deps ?? const DepsMap(packages: {}),
  native: native ?? NativeConfig(const {}),
  decisions: decisions,
  teamNotes: teamNotes,
);

const _screen = 'lib/ui/booking/widgets/booking_screen.dart';
const _viewModel = 'lib/ui/booking/view_models/booking_viewmodel.dart';
const _repository = 'lib/data/repositories/booking/booking_repository.dart';
const _service = 'lib/data/services/api/api_client.dart';
const _model = 'lib/domain/models/booking.dart';

/// The `booking` feature of [sampleKnowledge].
const sampleFeatures = FeaturesMap(
  features: {
    'booking': Feature(
      folder: 'lib/ui/booking',
      viewModels: [CodeRef(name: 'BookingViewModel', file: _viewModel)],
      screens: [CodeRef(name: 'BookingScreen', file: _screen)],
      repositories: [CodeRef(name: 'BookingRepository', file: _repository)],
      services: [CodeRef(name: 'ApiClient', file: _service)],
      models: [CodeRef(name: 'Booking', file: _model)],
      tests: ['test/ui/booking/view_models/booking_viewmodel_test.dart'],
      files: [_viewModel, _screen],
    ),
  },
);

/// The symbols of [sampleKnowledge]. `BookingViewModel` has no summary.
const sampleSymbols = SymbolsMap(
  symbols: [
    MapSymbol(
      name: 'BookingRepository',
      kind: SymbolKind.classKind,
      file: _repository,
      line: 4,
      layer: 'data.repository',
      summary: 'Loads and saves bookings.',
    ),
    MapSymbol(
      name: 'ApiClient',
      kind: SymbolKind.classKind,
      file: _service,
      line: 6,
      layer: 'data.service',
      summary: 'Talks to the booking API.',
    ),
    MapSymbol(
      name: 'Booking',
      kind: SymbolKind.classKind,
      file: _model,
      line: 2,
      layer: 'domain',
      summary: 'One booking.',
    ),
    MapSymbol(
      name: 'BookingViewModel',
      kind: SymbolKind.classKind,
      file: _viewModel,
      line: 9,
      layer: 'ui',
      feature: 'booking',
    ),
    MapSymbol(
      name: 'BookingScreen',
      kind: SymbolKind.classKind,
      file: _screen,
      line: 8,
      layer: 'ui',
      feature: 'booking',
      summary: 'Shows one booking.',
    ),
  ],
);

/// The routes of [sampleKnowledge]: `/` redirects to `/booking`.
const sampleRoutes = RoutesMap(
  routes: [
    MapRoute(
      path: '/',
      redirect: true,
      redirectTo: '/booking',
      file: 'lib/routing/router.dart',
      line: 10,
    ),
    MapRoute(
      path: '/booking',
      name: 'booking',
      screen: CodeRef(name: 'BookingScreen', file: _screen),
      file: 'lib/routing/router.dart',
      line: 14,
    ),
  ],
  routers: [
    MapRouter(file: 'lib/routing/router.dart', line: 8, redirect: false),
  ],
);

/// A decision entry for page tests.
DecisionEntry decisionEntry(
  int number,
  String title, {
  DecisionStatus status = DecisionStatus.accepted,
  String why = 'Because.',
  String? date = '2026-10-01',
  List<String> paths = const [],
  int? supersedes,
  DecisionRecord? supersededBy,
  DecisionStatus? shown,
}) => DecisionEntry(
  DecisionRecord(
    file: '${decisionNumberText(number)}-x.md',
    number: number,
    title: title,
    status: status,
    date: date,
    supersedes: supersedes,
    paths: paths,
    why: why,
  ),
  status: shown ?? status,
  supersededBy: supersededBy,
);

/// A [DecisionSet] of [entries], with each file's bytes made from its title
/// and reason, so a changed entry changes the set's digest.
DecisionSet decisionSet(
  List<DecisionEntry> entries, {
  List<UnreadableDecision> unreadable = const [],
  Map<int, List<String>> duplicates = const {},
  List<String> problems = const [],
}) => DecisionSet(
  entries: entries,
  unreadable: unreadable,
  duplicates: duplicates,
  problems: problems,
  bytes: {
    for (final entry in entries)
      entry.record.file: utf8.encode(
        '${entry.record.title}\n${entry.record.status.name}\n'
        '${entry.record.why}',
      ),
  },
);

/// A page source for renderer tests: it returns [sections_], or throws
/// [failure].
final class FakeDocPage implements DocPage {
  /// Creates the page source.
  const FakeDocPage(this.sections_, {this.id = 'fake', this.failure});

  /// What it returns.
  final List<DocSection> sections_;

  /// What it throws instead, when set.
  final Object? failure;

  @override
  final String id;

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    if (failure case final failure?) throw failure;
    return sections_;
  }
}
