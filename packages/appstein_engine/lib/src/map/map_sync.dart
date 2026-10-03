import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../delta/delta_collector.dart';
import '../delta/delta_facts.dart';
import '../host/file_errors.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../knowledge/generated_file.dart';
import '../knowledge/sync_timings.dart';
import '../packs/pack.dart';
import 'analyzer_cache.dart';
import 'dependencies.dart';
import 'layers.dart';
import 'map_inputs.dart';
import 'project_analysis.dart';
import 'project_packages.dart';
import 'symbols.dart';

/// What was done about the project's packages before the map was built.
enum PackagesAction {
  /// They were fresh, so nothing was run.
  upToDate,

  /// `flutter pub get` ran and worked.
  fetched,

  /// `flutter pub get` ran and failed, so the map was skipped.
  fetchFailed,
}

/// What the project-map part of a sync did.
final class MapReport {
  /// Creates the report.
  const MapReport({
    required this.packages,
    required this.packagesReason,
    this.skipped,
    this.deltaError,
    this.deltaErrorType,
  });

  /// What was done about the packages.
  final PackagesAction packages;

  /// Why: the packages' status (words that follow "because"), or, after a
  /// failed fetch, what went wrong, with the end of Flutter's output.
  final String packagesReason;

  /// Why the map wasn't written; null when it was.
  final String? skipped;

  /// The error that stopped the version delta's facts being collected
  /// although the map was written (an Appstein bug), in full, for the
  /// person running the sync; null otherwise. Never set when [skipped] is.
  /// It may hold a machine path, so it never goes into a generated file.
  final String? deltaError;

  /// The type of [deltaError], such as `StateError`: what `delta.md` says
  /// and hashes, since it holds no machine path. Set exactly when
  /// [deltaError] is.
  final String? deltaErrorType;
}

/// Collects the version delta's facts from an open analysis; [collectDelta]
/// is the real one. A seam for tests.
typedef DeltaCollector =
    Future<DeltaFacts> Function(
      ProjectAnalysis analysis, {
      required String dartSdkPath,
    });

/// The project map, built but not yet written.
final class MapBuild {
  /// Creates the build.
  const MapBuild({
    required this.files,
    required this.report,
    this.inputs,
    this.delta,
    this.cache,
    this.cacheRetry,
  });

  /// The analyzer cache the analysis used, to be saved; null when the map
  /// was skipped or there was no cache.
  final AnalyzerCache? cache;

  /// The analyzer's error, in one line, that made the analysis run again
  /// with an empty cache; null when it didn't.
  final String? cacheRetry;

  /// The map files; empty when the map was skipped.
  final List<GeneratedFile> files;

  /// What happened.
  final MapReport report;

  /// What the map was built from; null when the map was skipped.
  final MapInputs? inputs;

  /// The input hash every map file shares; null when the map was skipped.
  String? get inputHash => inputs?.inputHash;

  /// The deprecated, removed and moved APIs the project can reach, for the
  /// version delta (spec §6.4); null when the map was skipped.
  final DeltaFacts? delta;
}

/// Builds the project map (spec §6.5).
///
/// First it makes sure the packages are fetched, the way Flutter does. Then
/// it resolves the project, runs the packs' extractors (official_mvvm's
/// features and routes), and builds the generic files: symbols, layers and
/// deps.
///
/// While the analysis is open, it also collects the version delta's facts
/// ([collectDelta]); `KnowledgeSync` renders them into `delta.md`. If that
/// fails for any reason, the map is still returned, with the error in
/// [MapReport.deltaError]: a sync never fails because of the delta.
final class MapSync {
  /// Creates the sync. [runner] runs `flutter pub get` (a real process by
  /// default); [deltaCollector] is [collectDelta] by default.
  MapSync({
    required this.environment,
    required this.appsteinVersion,
    required this.packs,
    ProcessRunner? runner,
    DeltaCollector? deltaCollector,
  }) : runner = runner ?? const SystemProcessRunner(),
       deltaCollector = deltaCollector ?? collectDelta;

  /// The machine.
  final HostEnvironment environment;

  /// The version of the running Appstein; part of every input hash.
  final String appsteinVersion;

  /// The packs whose extractors and layer rules apply.
  final List<Pack> packs;

  /// Runs `flutter pub get`.
  final ProcessRunner runner;

  /// Collects the version delta's facts.
  final DeltaCollector deltaCollector;

  /// Builds the map of the project at [projectRoot], for Flutter
  /// [flutterVersion] at [flutterRoot]. `dart:` libraries are read from
  /// [dartSdkPath], by default the Flutter SDK's `bin/cache/dart-sdk`.
  ///
  /// It never throws for the project's own problems: a failed fetch, an
  /// incomplete SDK, a damaged `pubspec.lock` or `pubspec.yaml`, or an
  /// unreadable project file is reported in [MapBuild.report], with no
  /// files.
  ///
  /// With a [cache], the analyzer keeps its work there. An error inside the
  /// analyzer while using the cache makes it analyze once more with an empty
  /// cache ([MapBuild.cacheRetry]).
  ///
  /// [timings] hears how long each step took.
  Future<MapBuild> build(
    String projectRoot, {
    required String flutterVersion,
    required String flutterRoot,
    String? dartSdkPath,
    AnalyzerCache? cache,
    SyncTimings? timings,
  }) async {
    final timed = timings ?? SyncTimings();
    var status = timed.time(
      'packages check',
      () => checkPackages(projectRoot, flutterVersion: flutterVersion),
    );
    final reason = status.reason;
    var action = PackagesAction.upToDate;
    if (!status.fresh) {
      final failure = await timed.timeAsync(
        'flutter pub get',
        () => fetchPackages(
          projectRoot,
          flutterRoot: flutterRoot,
          os: environment.os,
          runner: runner,
        ),
      );
      if (failure != null) {
        return MapBuild(
          files: const [],
          report: MapReport(
            packages: PackagesAction.fetchFailed,
            packagesReason: failure,
            skipped: 'the packages could not be fetched',
          ),
        );
      }
      action = PackagesAction.fetched;
      // A first fetch may have created the workspace reference.
      status = timed.time(
        'packages check',
        () => checkPackages(projectRoot, flutterVersion: flutterVersion),
      );
    }

    final sdk = dartSdkPath ?? p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
    Future<MapBuild> analyzeWith(AnalyzerCache? cache, {String? retried}) =>
        catchAnalyzerErrors(
          () => _analyze(
            projectRoot,
            status: status,
            action: action,
            reason: reason,
            flutterVersion: flutterVersion,
            flutterRoot: flutterRoot,
            sdk: sdk,
            cache: cache,
            retried: retried,
            timings: timed,
          ),
        );
    try {
      return await analyzeWith(cache);
    } on Object catch (error) {
      // Only an error inside the analyzer, or an Appstein bug, gets here:
      // the project's own problems are returned as a skipped map. A cache
      // entry holding garbage is one such error, so analyze once more with
      // an empty cache, which then replaces the old one. Any other error
      // happens again and is thrown.
      if (cache == null) rethrow;
      // The failed analysis is abandoned, not disposed: its futures never
      // complete and it may still use CPU during the retry; the process
      // still exits normally.
      return analyzeWith(
        AnalyzerCache.empty(cache.path),
        retried: '${error.runtimeType}: ${'$error'.split('\n').first}',
      );
    }
  }

  Future<MapBuild> _analyze(
    String projectRoot, {
    required PackagesStatus status,
    required PackagesAction action,
    required String reason,
    required String flutterVersion,
    required String flutterRoot,
    required String sdk,
    required AnalyzerCache? cache,
    required String? retried,
    required SyncTimings timings,
  }) async {
    // Read before the analysis, not after: a file edited while it runs must
    // leave the old hash behind, so the next `sync --detect` rebuilds.
    final inputs = timings.time(
      'map inputs',
      () => readMapInputs(
        projectRoot,
        workspaceRoot: status.workspaceRoot,
        flutterVersion: flutterVersion,
        flutterRoot: flutterRoot,
        packs: packs,
        appsteinVersion: appsteinVersion,
        environment: environment,
      ),
    );
    final ProjectAnalysis analysis;
    try {
      analysis = await timings.timeAsync(
        'analysis',
        () => ProjectAnalysis.analyze(
          projectRoot,
          dartSdkPath: sdk,
          cache: cache,
        ),
      );
    } on ProjectAnalysisException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped: error.message,
        ),
      );
    }
    try {
      final extracting = Stopwatch()..start();
      final bodies = <String, Map<String, Object?>>{};
      for (final pack in packs) {
        for (final extractor in pack.extractors) {
          for (final MapEntry(:key, :value)
              in extractor.extract(analysis).entries) {
            if (bodies.containsKey(key)) {
              throw StateError('Two packs write $key.');
            }
            bodies[key] = value;
          }
        }
      }
      final featuresBody = bodies[MapFiles.features];
      final features = featuresBody == null
          ? null
          : FeaturesMap.fromJson(featuresBody);
      // Built once: FeaturesMap.featureOf scans every feature's file list,
      // and it is asked once per file. The first feature that lists a file
      // wins, as in featureOf.
      final featureByFile = <String, String>{};
      for (final MapEntry(key: name, value: feature)
          in features?.features.entries ?? <MapEntry<String, Feature>>[]) {
        for (final file in [...feature.files, ...feature.tests]) {
          featureByFile.putIfAbsent(file, () => name);
        }
      }
      String? featureOf(String file) => featureByFile[file];
      final rules = packs
          .where((pack) => pack.kind == PackKind.stack)
          .firstOrNull
          ?.layerRules;
      final matcher = rules == null ? null : LayerMatcher(rules);
      final lockFile = p.join(status.workspaceRoot, 'pubspec.lock');
      bodies[MapFiles.symbols] = buildSymbols(
        analysis,
        layerOf: (file) => matcher?.tagFor(file),
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.layers] = buildLayers(
        analysis,
        rules: rules,
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.deps] = buildDeps(analysis, lockFile: lockFile).toJson();
      timings.add('extractors', extracting.elapsed);
      // While the analysis is still open: the delta walks what the imports
      // expose.
      // Any failure here (an analyzer internal, a bug) must not cost the
      // map: it is reported instead. `on Object` is deliberate; the lints in
      // use have no rule against catching Errors.
      DeltaFacts? delta;
      String? deltaError;
      String? deltaErrorType;
      try {
        delta = await timings.timeAsync(
          'delta facts',
          () => deltaCollector(analysis, dartSdkPath: sdk),
        );
      } on Object catch (error) {
        delta = null;
        deltaError = '$error';
        deltaErrorType = '${error.runtimeType}';
      }

      final paths = bodies.keys.toList()..sort();
      return MapBuild(
        files: [
          for (final path in paths)
            GeneratedFile(
              path: path,
              body: bodies[path]!,
              inputHash: inputs.inputHash,
            ),
        ],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          deltaError: deltaError,
          deltaErrorType: deltaErrorType,
        ),
        inputs: inputs,
        delta: delta,
        cache: cache,
        cacheRetry: retried,
      );
    } on DependenciesException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped: '${error.message}; run `flutter pub get`',
        ),
      );
    } on FileSystemException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped:
              'the project files could not be read '
              '(${fileErrorReason(error)})',
        ),
      );
    } finally {
      await timings.timeAsync('analysis dispose', analysis.dispose);
    }
  }
}
