import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../map/map_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'knowledge_store.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2): the platform layer
/// and the project map. Both are built first, then written under one lock,
/// with a `state.json` that lists them.
final class KnowledgeSync {
  /// Creates the sync. [packs] are the project's packs (the CLI chooses
  /// them from `appstein.yaml`), [notes] default to the compiled-in curated
  /// notes, [runner] runs `flutter pub get`, and [clock] gives the time.
  KnowledgeSync({
    required this.environment,
    required this.appsteinVersion,
    this.packs = const [],
    CuratedNotes? notes,
    ProcessRunner? runner,
    this._clock,
    this.lockTimeout = const Duration(seconds: 10),
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

  final DateTime Function()? _clock;

  /// Syncs the project at [projectRoot]. [sdk] is the SDK detection to use
  /// (by default it is detected for the project); [dartSdkPath] overrides
  /// where `dart:` libraries are read from, for tests.
  ///
  /// The map is skipped, with the reason in [SyncReport.map], when the
  /// packages can't be fetched or the Dart SDK is incomplete. The platform
  /// layer is still written.
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
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: platform.sdk,
        files: await store.writeAll(
          [...platform.files, ...map.files],
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
}
