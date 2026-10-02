import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../delta/delta_document.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../index/index_document.dart';
import '../index/index_sources.dart';
import '../map/analyzer_cache.dart';
import '../map/map_inputs.dart';
import '../map/map_sync.dart';
import '../map/project_packages.dart';
import '../native/native_extractor.dart';
import '../native/native_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'canonical_json.dart';
import 'freshness.dart';
import 'generated_file.dart';
import 'input_hash.dart';
import 'knowledge_lock.dart';
import 'knowledge_store.dart';
import 'knowledge_write_exception.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2, §6.3): the platform
/// layer, the version delta, the project map, the native config and
/// `INDEX.md`. All are built first, then written under one lock, with a
/// `state.json` that lists them.
///
/// [run] rebuilds everything; [detect] rebuilds only when something the
/// knowledge reads changed ([freshness]).
final class KnowledgeSync {
  /// Creates the sync. [packs] are the project's packs (the CLI chooses
  /// them from `appstein.yaml`), [notes] default to the compiled-in curated
  /// notes, [runner] runs `flutter pub get`, [clock] gives the time, and
  /// [baseline] is `delta.baseline` from `appstein.yaml`.
  KnowledgeSync({
    required this.environment,
    required this.appsteinVersion,
    this.packs = const [],
    CuratedNotes? notes,
    ProcessRunner? runner,
    this._clock,
    this.lockTimeout = const Duration(seconds: 10),
    this.baseline = '3.16',
    this.deltaCollector,
    this.analyzerCache = true,
  }) : notes = notes ?? CuratedNotes.bundled(),
       runner = runner ?? const SystemProcessRunner();

  /// The machine.
  final HostEnvironment environment;

  /// The version of the running Appstein.
  final String appsteinVersion;

  /// The project's packs.
  final List<Pack> packs;

  /// The curated notes.
  final CuratedNotes notes;

  /// Runs `flutter pub get`.
  final ProcessRunner runner;

  /// How long to wait for another writer's lock.
  final Duration lockTimeout;

  /// How far back the delta's curated notes reach (spec §6.4, §7); `3.16`
  /// is the default of `delta.baseline`.
  final String baseline;

  /// Collects the delta's facts; [collectDelta] when null. For tests.
  final DeltaCollector? deltaCollector;

  /// Whether the analyzer keeps its work in `.dart_tool/appstein/` between
  /// syncs (spec §6.2). Only tests turn it off, to compare the knowledge
  /// with and without it.
  final bool analyzerCache;

  final DateTime Function()? _clock;

  /// Syncs the project at [projectRoot], rebuilding everything. [sdk] is the
  /// SDK detection to use (by default it is detected for the project);
  /// [dartSdkPath] overrides where `dart:` libraries are read from, for
  /// tests.
  ///
  /// The map is skipped, with the reason in [SyncReport.map], when the
  /// packages can't be fetched or the Dart SDK is incomplete. The platform
  /// layer and a notes-only `delta.md` are still written.
  ///
  /// `map/native.json` is written either way: the platform packs read the
  /// native files without the analysis. A platform pack that fails costs only
  /// its own section, and the error is in [SyncReport.native].
  ///
  /// `INDEX.md` is written last, after every other file, since it summarizes
  /// them; when the map was skipped, it says so.
  ///
  /// The analyzer cache in `.dart_tool/appstein/` (spec §6.2) is read first
  /// and saved last; what happened to it is in [SyncReport.analyzerCache].
  ///
  /// When only collecting the delta's facts fails (an Appstein bug), the
  /// map and the platform layer are written, `delta.md` holds only the
  /// notes and names the error's type, and the error is in
  /// [MapReport.deltaError]. The sync doesn't fail.
  ///
  /// [SyncReport.changed] lists the input files that changed since the last
  /// sync, and `state.json` records them for `verify --fast` (spec §5.4).
  ///
  /// Throws `SyncException` when no usable SDK is found, a
  /// `KnowledgeLockTimeout` when another writer holds the lock too long,
  /// and a `KnowledgeWriteException` when a file can't be written.
  Future<SyncReport> run(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async => _rebuild(
    projectRoot,
    _prepare(projectRoot, sdk: sdk),
    dartSdkPath: dartSdkPath,
  );

  /// `appstein sync --detect` (spec §5.3, §5.4): rebuilds, as [run] does,
  /// only when [freshness] finds something changed, saying why in
  /// [SyncReport.rebuiltBecause].
  ///
  /// When nothing changed, it builds and writes nothing, and the report has
  /// [SyncReport.current]. The first such call after a rebuild empties
  /// `state.json`'s change list, so `verify --fast` checks each change once.
  /// It does that under the lock, and only if `state.json` is still the one
  /// it checked. When the lock stays busy past [lockTimeout], it leaves the
  /// list for a later call and still reports current.
  ///
  /// Throws as [run] does.
  Future<SyncReport> detect(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async {
    final prepared = _prepare(projectRoot, sdk: sdk);
    final freshness = _freshness(projectRoot, prepared);
    if (!freshness.current) {
      return _rebuild(
        projectRoot,
        prepared,
        dartSdkPath: dartSdkPath,
        reasons: freshness.reasons,
      );
    }
    final checked = freshness.state!;
    if (checked.changed.isNotEmpty) {
      final store = KnowledgeStore(projectRoot, clock: _clock);
      try {
        await store.locked(() async {
          final now = store.readState().state;
          if (now != null &&
              canonicalJson(now.toJson()) == canonicalJson(checked.toJson())) {
            await store.writeState(
              KnowledgeState(
                formatVersion: now.formatVersion,
                appsteinVersion: now.appsteinVersion,
                lastSync: now.lastSync,
                files: now.files,
                sources: now.sources,
                written: now.written,
                changed: const [],
              ),
            );
          }
        }, timeout: lockTimeout);
      } on KnowledgeLockTimeout {
        // Nothing is stale, so a hook mustn't fail over a busy lock. The
        // writer holding it is writing a new state.json anyway, which the
        // check above would no longer match; the list is emptied by a later
        // detect.
      }
    }
    final platform = prepared.platform;
    return SyncReport(
      sdk: platform.sdk,
      files: const {},
      newestNotes: platform.newestNotes,
      fallbacks: platform.fallbacks,
      current: true,
    );
  }

  /// Whether the `.appstein/` of the project at [projectRoot] holds what a
  /// sync would write now, without analyzing or writing anything.
  ///
  /// It runs a sync's cheap steps (the platform layer, the packages check,
  /// the map's inputs, native config and INDEX.md's sources). It computes
  /// each file's input hash the way a sync does, and compares them with
  /// `state.json`. It also finds the knowledge out of date when:
  /// - the packages need `flutter pub get`;
  /// - the last sync skipped the map;
  /// - another Appstein wrote `state.json`;
  /// - a file's bytes differ from what was written.
  ///
  /// Throws `SyncException` when no usable SDK is found.
  Freshness freshness(String projectRoot, {SdkDetection? sdk}) =>
      _freshness(projectRoot, _prepare(projectRoot, sdk: sdk));

  _Prepared _prepare(String projectRoot, {SdkDetection? sdk}) {
    final platform = PlatformSync(
      environment: environment,
      appsteinVersion: appsteinVersion,
      notes: notes,
      clock: _clock,
    ).build(projectRoot, sdk: sdk);
    final packages = checkPackages(
      projectRoot,
      flutterVersion: platform.sdk.flutterVersion,
    );
    return _Prepared(
      platform: platform,
      packages: packages,
      mapInputs: readMapInputs(
        projectRoot,
        workspaceRoot: packages.workspaceRoot,
        flutterVersion: platform.sdk.flutterVersion,
        flutterRoot: platform.location.root,
        packs: packs,
        appsteinVersion: appsteinVersion,
        environment: environment,
      ),
      native: _native(projectRoot, platform),
      sources: readIndexSources(projectRoot),
    );
  }

  Future<SyncReport> _rebuild(
    String projectRoot,
    _Prepared prepared, {
    String? dartSdkPath,
    List<String> reasons = const [],
  }) async {
    final platform = prepared.platform;
    final store = KnowledgeStore(projectRoot, clock: _clock);
    final previous = store.readState().state;
    final cache = analyzerCache
        ? AnalyzerCache.open(analyzerCachePath(projectRoot))
        : null;
    final map =
        await MapSync(
          environment: environment,
          appsteinVersion: appsteinVersion,
          packs: packs,
          runner: runner,
          deltaCollector: deltaCollector,
        ).build(
          projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          flutterRoot: platform.location.root,
          dartSdkPath: dartSdkPath,
          cache: cache,
        );
    // Native config needs no analysis, so it is built even when the map was
    // skipped. It runs after MapSync because a `flutter pub get` the map ran
    // rewrites the generated Package.swift it reads.
    final native = _native(projectRoot, platform);
    final delta = _delta(platform, map);
    // Last: it summarizes the other files.
    final index = _index(platform, map, native, delta, prepared.sources);
    // The map read its inputs after any fetch, which may change
    // pubspec.lock.
    final sources = map.inputs?.sources ?? prepared.mapInputs.sources;
    final changed = changedSources(previous?.sources, sources);
    return store.locked(() async {
      final files = await store.writeAll(
        [...platform.files, delta, ...map.files, ?native.file, index],
        appsteinVersion: appsteinVersion,
        sdkVersion: platform.sdk.flutterVersion,
        sources: sources,
        changed: changed,
      );
      // After the knowledge, inside the lock, so two syncs never write the
      // same temporary file. The cache only makes the next sync faster, so
      // failing to save it is a warning.
      String? saveError;
      if (map.cache case final used? when used.changed) {
        try {
          await used.save();
        } on KnowledgeWriteException catch (error) {
          saveError = error.reason;
          // The cache must never fail a sync: the knowledge is already
          // written, so any other error saving it (an `ArgumentError` from
          // encoding a key that isn't ASCII, say) is a warning too.
        } on Object catch (error) {
          saveError = '$error';
        }
      }
      return SyncReport(
        sdk: platform.sdk,
        files: files,
        newestNotes: platform.newestNotes,
        fallbacks: platform.fallbacks,
        map: map.report,
        native: native.report,
        // With no earlier state there is nothing to compare with.
        changed: previous == null ? const [] : changed,
        rebuiltBecause: reasons,
        analyzerCache: cache == null
            ? null
            : AnalyzerCacheReport(
                load: cache.load,
                damage: cache.damage,
                retried: map.cacheRetry,
                saveError: saveError,
              ),
      );
    }, timeout: lockTimeout);
  }

  Freshness _freshness(String projectRoot, _Prepared prepared) {
    final store = KnowledgeStore(projectRoot);
    final read = store.readState();
    final sources = prepared.mapInputs.sources;
    final state = read.state;
    if (state == null) {
      return Freshness(
        reasons: [read.problem!],
        changed: changedSources(null, sources),
      );
    }
    final platform = prepared.platform;
    final reasons = [
      if (state.appsteinVersion != appsteinVersion)
        'the last sync was made by Appstein ${state.appsteinVersion}',
      if (state.formatVersion != knowledgeFormatVersion)
        'state.json is in format ${state.formatVersion}',
      if (!prepared.packages.fresh)
        'the packages need `flutter pub get`: ${prepared.packages.reason}',
      if (!state.files.containsKey(MapFiles.symbols))
        'the last sync could not build the project map',
    ];
    // Each file's input hash, computed as a sync computes it. The map's
    // files all share the map's hash; which files those are depends only on
    // the packs, which are part of that hash.
    final mapHash = prepared.mapInputs.inputHash;
    final expected = <String, String>{
      for (final file in platform.files) file.path: file.inputHash,
      if (prepared.native.file case final file?) file.path: file.inputHash,
      for (final path in state.files.keys)
        if (path.startsWith('map/') && path != MapFiles.native) path: mapHash,
      deltaPath: _deltaHash(platform.sdk, mapHash),
    };
    expected[indexPath] = _indexHash(expected, prepared.sources);
    for (final path in {
      ...expected.keys,
      ...state.files.keys,
    }.toList()..sort()) {
      if (expected[path] != state.files[path]) {
        reasons.add('$path is out of date');
      }
    }
    for (final MapEntry(key: path, value: hash) in state.written.entries) {
      final actual = store.fileHash(path);
      if (actual == null) {
        reasons.add('$path is missing');
      } else if (actual != hash) {
        reasons.add('$path was changed by hand');
      }
    }
    return Freshness(
      reasons: reasons,
      changed: changedSources(state.sources, sources),
      state: state,
    );
  }

  NativeBuild _native(String projectRoot, PlatformBuild platform) =>
      NativeSync(appsteinVersion: appsteinVersion, packs: packs).build(
        NativeContext(
          projectRoot: projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          channel: platform.sdk.channel,
          environment: environment,
          android: platform.toolchain.android,
        ),
      );

  /// `delta.md`: the notes, and the delta facts when they were collected.
  /// Its input hash covers the map's own hash (so the project's code,
  /// packages and Flutter version) or, with no facts, the reason they are
  /// missing, plus the notes, the baseline and the language version.
  GeneratedFile _delta(PlatformBuild platform, MapBuild map) {
    final sdk = platform.sdk;
    final internalError = map.report.deltaErrorType;
    // With no facts, the hashed reason is what delta.md says: the map's skip
    // reason, or only the error's type, never its message, which may hold
    // a machine path or differ from run to run.
    final skipped =
        map.report.skipped ??
        (internalError == null ? null : 'internal error ($internalError)');
    final facts = map.delta;
    final markdown = renderDelta(
      DeltaInputs(
        flutterVersion: sdk.flutterVersion,
        languageVersion: sdk.languageVersion,
        baseline: baseline,
        coverage: sdk.notesCoverage ?? NotesCoverage.partial,
        newestNotes: platform.newestNotes,
        notes: deltaNotes(
          notes,
          flutterVersion: sdk.flutterVersion,
          baseline: baseline,
        ),
        facts: facts,
        skipped: map.report.skipped,
        internalError: map.report.skipped == null ? internalError : null,
      ),
    );
    return GeneratedFile.markdown(
      path: deltaPath,
      markdown: markdown,
      inputHash: _deltaHash(
        sdk,
        // Facts exist only when the map ran, so then its hash is there.
        facts == null ? 'skipped: $skipped' : map.inputHash!,
      ),
    );
  }

  /// The input hash of `delta.md`: [mapPart] (the map's input hash, or why
  /// there are no facts), the notes, the baseline, the language version and
  /// the Flutter version.
  String _deltaHash(SdkInfo sdk, String mapPart) => inputHash(
    {
      'map': utf8.encode(mapPart),
      ...notes.inputs,
      'baseline': utf8.encode(baseline),
      'languageVersion': utf8.encode(sdk.languageVersion ?? ''),
      'flutter': utf8.encode(sdk.flutterVersion),
    },
    appsteinVersion: appsteinVersion,
    formatVersion: knowledgeFormatVersion,
  );

  /// `INDEX.md` (spec §6.3): a summary of the other files, the project's
  /// decisions and its current work, within [indexByteBudget] bytes. Its
  /// input hash covers the other files' input hashes, the project files it
  /// reads, and the packs.
  GeneratedFile _index(
    PlatformBuild platform,
    MapBuild map,
    NativeBuild native,
    GeneratedFile delta,
    IndexSources sources,
  ) {
    final sdk = platform.sdk;
    final hash = _indexHash({
      for (final file in [...platform.files, delta, ...map.files, ?native.file])
        file.path: file.inputHash,
    }, sources);
    final stack = packs
        .where((pack) => pack.kind == PackKind.stack)
        .firstOrNull;
    final featuresBody = map.files
        .where((file) => file.path == MapFiles.features)
        .firstOrNull
        ?.body;
    final nativeBody = native.file?.body;
    final skipped = map.report.skipped;
    final inputs = IndexInputs(
      projectName: sources.projectName,
      sdk: sdk,
      appsteinVersion: appsteinVersion,
      newestNotes: platform.newestNotes,
      stackPack: stack?.id,
      platforms: sources.platforms,
      appIds: appIdLines(
        nativeBody == null ? null : NativeConfig.fromJson(nativeBody),
      ),
      features: featuresBody == null
          ? null
          : indexFeatures(FeaturesMap.fromJson(featuresBody)),
      featuresMissing: skipped == null
          ? 'no stack pack, so no features'
          : 'the project map was skipped: $skipped',
      layers: stack?.layerRules?.layers,
      notes: [
        for (final note in deltaNotes(
          notes,
          flutterVersion: sdk.flutterVersion,
          baseline: baseline,
        ))
          if (!needsNewerLanguage(note, sdk.languageVersion)) note,
      ],
      apiCounts: switch (map.delta) {
        final facts? => DeltaCounts.of(facts),
        null => null,
      },
      decisions: sources.decisions,
      decisionsError: sources.decisionsError,
      currentWork: sources.currentWork,
      currentWorkError: sources.currentWorkError,
    );
    final budget = indexBodyBudget(
      KnowledgeMeta(
        // Any time: every one has the same length.
        generatedAt: formatKnowledgeTime(DateTime.utc(2000)),
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdk.flutterVersion,
        inputHash: hash,
      ),
    );
    return GeneratedFile.markdown(
      path: indexPath,
      markdown: renderIndex(inputs, byteBudget: budget),
      inputHash: hash,
    );
  }

  /// The input hash of `INDEX.md`: [fileHashes] (each other file's input
  /// hash, by path), the project files [sources] read, and the packs.
  String _indexHash(Map<String, String> fileHashes, IndexSources sources) =>
      inputHash(
        {
          for (final MapEntry(key: path, value: hash) in fileHashes.entries)
            'file:$path': utf8.encode(hash),
          ...sources.inputs,
          'packs': utf8.encode(
            [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
          ),
        },
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
      );
}

/// What a sync builds before the analysis: everything [KnowledgeSync]
/// needs to decide whether the knowledge is current.
final class _Prepared {
  const _Prepared({
    required this.platform,
    required this.packages,
    required this.mapInputs,
    required this.native,
    required this.sources,
  });

  final PlatformBuild platform;
  final PackagesStatus packages;
  final MapInputs mapInputs;
  final NativeBuild native;
  final IndexSources sources;
}
