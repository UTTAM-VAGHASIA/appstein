import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../host/host_environment.dart';
import '../map/map_sync.dart';
import '../notes/curated_notes.dart';
import '../sdk/flutter_sdk_locator.dart';
import '../sdk/sdk_detector.dart';
import '../toolchain/toolchain_reader.dart';
import 'canonical_json.dart';
import 'generated_file.dart';
import 'input_hash.dart';
import 'knowledge_store.dart';

/// Thrown when `appstein sync` can't run because no usable Flutter SDK was
/// found.
final class SyncException implements Exception {
  /// Creates the exception.
  const SyncException(this.problem, this.fixHint);

  /// What is wrong.
  final String problem;

  /// What the user should do about it.
  final String fixHint;

  @override
  String toString() => problem;
}

/// What one sync did.
final class SyncReport {
  /// Creates the report.
  const SyncReport({
    required this.sdk,
    required this.files,
    required this.newestNotes,
    required this.fallbacks,
    this.map,
  });

  /// What the project-map part of the sync did; null when only the platform
  /// layer was synced ([PlatformSync.run]).
  final MapReport? map;

  /// The SDK facts written to `sdk.json`.
  final SdkInfo sdk;

  /// Each generated file, by its path inside `.appstein/`: true when it was
  /// written, false when its inputs hadn't changed.
  final Map<String, bool> files;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// Why parts of the toolchain came from the notes or are unknown
  /// (`toolchain.fallback`, spec §12).
  final List<String> fallbacks;
}

/// The platform layer, built but not yet written.
final class PlatformBuild {
  /// Creates the build.
  const PlatformBuild({
    required this.sdk,
    required this.location,
    required this.files,
    required this.newestNotes,
    required this.fallbacks,
  });

  /// The SDK facts, with the notes coverage.
  final SdkInfo sdk;

  /// Where the Flutter SDK is.
  final SdkLocation location;

  /// `platform/sdk.json` and `platform/toolchain.json`.
  final List<GeneratedFile> files;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// Why parts of the toolchain came from the notes or are unknown.
  final List<String> fallbacks;
}

/// Writes the platform layer of `.appstein/` (spec §6.1, §6.2):
/// `platform/sdk.json`, `platform/toolchain.json` and `state.json`.
final class PlatformSync {
  /// Creates the sync. [notes] defaults to the notes compiled into
  /// Appstein, and [clock] to the real time.
  PlatformSync({
    required this.environment,
    required this.appsteinVersion,
    CuratedNotes? notes,
    this._clock,
    this.lockTimeout = const Duration(seconds: 10),
  }) : notes = notes ?? CuratedNotes.bundled();

  /// Where `sdk.json` lives inside `.appstein/`.
  static const sdkPath = 'platform/sdk.json';

  /// Where `toolchain.json` lives inside `.appstein/`.
  static const toolchainPath = 'platform/toolchain.json';

  /// The machine, used to find the Flutter SDK.
  final HostEnvironment environment;

  /// The version of the running Appstein, recorded in every file.
  final String appsteinVersion;

  /// The curated notes.
  final CuratedNotes notes;

  /// How long to wait for another writer's lock.
  final Duration lockTimeout;

  final DateTime Function()? _clock;

  /// Builds the platform layer of the project at [projectRoot] without
  /// writing it. [sdk] is the SDK detection to use; by default, the SDK is
  /// detected for the project.
  ///
  /// Throws [SyncException] when no usable SDK is found.
  PlatformBuild build(String projectRoot, {SdkDetection? sdk}) {
    final detection =
        sdk ?? SdkDetector(environment).detect(projectRoot: projectRoot);
    final info = detection.info;
    final location = detection.location;
    if (info == null || location == null) {
      throw SyncException(
        detection.problem ?? 'No Flutter SDK was found.',
        detection.fixHint ?? 'Run `appstein doctor` to see what is missing.',
      );
    }
    final sdkInfo = info.withNotesCoverage(
      notes.coverageFor(info.flutterVersion),
    );
    final reading = readToolchain(
      location.root,
      flutterVersion: info.flutterVersion,
      notes: notes,
    );
    final sdkBody = sdkInfo.toJson();
    final toolchainBody = reading.toolchain.toJson();
    String hash(Map<String, List<int>?> inputs) => inputHash(
      inputs,
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
    final hashes = {
      sdkPath: hash({'sdk.json': utf8.encode(canonicalJson(sdkBody))}),
      toolchainPath: hash({
        ...reading.inputs,
        ...notes.inputs,
        'flutter': utf8.encode(info.flutterVersion),
      }),
    };

    return PlatformBuild(
      sdk: sdkInfo,
      location: location,
      files: [
        GeneratedFile(
          path: sdkPath,
          body: sdkBody,
          inputHash: hashes[sdkPath]!,
        ),
        GeneratedFile(
          path: toolchainPath,
          body: toolchainBody,
          inputHash: hashes[toolchainPath]!,
        ),
      ],
      newestNotes: notes.newestMinor,
      fallbacks: reading.toolchain.fallbacks,
    );
  }

  /// Builds and writes the platform layer of the project at [projectRoot]
  /// alone. Production sync goes through `KnowledgeSync` (`appstein sync`
  /// uses it), which adds the project map. Don't call this from production
  /// code: it writes a `state.json` that lists only the platform files, so
  /// it would make `state.json` forget the map files. Tests use it to cover
  /// the platform layer by itself. [sdk] is the SDK detection to use.
  ///
  /// Throws [SyncException] when no usable SDK is found, a
  /// `KnowledgeLockTimeout` when another writer holds the lock too long,
  /// and a `KnowledgeWriteException` when a file can't be written.
  Future<SyncReport> run(String projectRoot, {SdkDetection? sdk}) async {
    final layer = build(projectRoot, sdk: sdk);
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: layer.sdk,
        files: await store.writeAll(
          layer.files,
          appsteinVersion: appsteinVersion,
          sdkVersion: layer.sdk.flutterVersion,
        ),
        newestNotes: layer.newestNotes,
        fallbacks: layer.fallbacks,
      ),
      timeout: lockTimeout,
    );
  }
}
