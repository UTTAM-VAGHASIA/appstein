import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../delta/delta_document.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../map/map_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'generated_file.dart';
import 'input_hash.dart';
import 'knowledge_store.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2): the platform layer,
/// the version delta and the project map. All are built first, then written
/// under one lock, with a `state.json` that lists them.
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

  final DateTime Function()? _clock;

  /// Syncs the project at [projectRoot]. [sdk] is the SDK detection to use
  /// (by default it is detected for the project); [dartSdkPath] overrides
  /// where `dart:` libraries are read from, for tests.
  ///
  /// The map is skipped, with the reason in [SyncReport.map], when the
  /// packages can't be fetched or the Dart SDK is incomplete. The platform
  /// layer and a notes-only `delta.md` are still written.
  ///
  /// Throws `SyncException` when no usable SDK is found, a
  /// `KnowledgeLockTimeout` when another writer holds the lock too long,
  /// and a `KnowledgeWriteException` when a file can't be written.
  Future<SyncReport> run(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async {
    final platform = PlatformSync(
      environment: environment,
      appsteinVersion: appsteinVersion,
      notes: notes,
      clock: _clock,
    ).build(projectRoot, sdk: sdk);
    final map =
        await MapSync(
          environment: environment,
          appsteinVersion: appsteinVersion,
          packs: packs,
          runner: runner,
        ).build(
          projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          flutterRoot: platform.location.root,
          dartSdkPath: dartSdkPath,
        );
    final delta = _delta(platform, map);
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: platform.sdk,
        files: await store.writeAll(
          [...platform.files, delta, ...map.files],
          appsteinVersion: appsteinVersion,
          sdkVersion: platform.sdk.flutterVersion,
        ),
        newestNotes: platform.newestNotes,
        fallbacks: platform.fallbacks,
        map: map.report,
      ),
      timeout: lockTimeout,
    );
  }

  /// `delta.md`: the notes, and the map's delta facts when it ran. Its
  /// input hash covers the map's own hash (so the project's code, packages
  /// and Flutter version), the notes, the baseline and the language version.
  GeneratedFile _delta(PlatformBuild platform, MapBuild map) {
    final sdk = platform.sdk;
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
        facts: map.delta,
        skipped: map.report.skipped,
      ),
    );
    return GeneratedFile.markdown(
      path: deltaPath,
      markdown: markdown,
      inputHash: inputHash(
        {
          'map': utf8.encode(map.inputHash ?? 'skipped: ${map.report.skipped}'),
          ...notes.inputs,
          'baseline': utf8.encode(baseline),
          'languageVersion': utf8.encode(sdk.languageVersion ?? ''),
          'flutter': utf8.encode(sdk.flutterVersion),
        },
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
      ),
    );
  }
}
