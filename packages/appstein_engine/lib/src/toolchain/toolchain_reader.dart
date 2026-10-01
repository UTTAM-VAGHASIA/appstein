import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../notes/curated_notes.dart';
import '../notes/notes_parser.dart';
import 'gradle_plugin_checks_parser.dart';
import 'gradle_utils_parser.dart';
import 'toolchain_files.dart';
import 'xcode_template_parser.dart';

/// The toolchain matrix for one Flutter SDK, and what it was read from.
final class ToolchainReading {
  /// Creates the reading.
  const ToolchainReading(this.toolchain, this.inputs);

  /// The matrix (spec §12).
  final Toolchain toolchain;

  /// Each SDK file in [ToolchainFiles.all] by `sdk:<path>`: its bytes, or
  /// null when it is missing. These feed the input hash of
  /// `toolchain.json`.
  final Map<String, List<int>?> inputs;
}

/// Reads the toolchain matrix (spec §12) for the Flutter SDK at [sdkRoot],
/// whose version is [flutterVersion].
///
/// Each part (Android, iOS, macOS) is read from the SDK's own files. A part
/// that can't be read comes from the newest notes file at or below
/// [flutterVersion], or is null when there is none. Either way, a sentence
/// in [Toolchain.fallbacks] says why. It never throws for a missing or
/// changed file.
ToolchainReading readToolchain(
  String sdkRoot, {
  required String flutterVersion,
  required CuratedNotes notes,
}) {
  final inputs = <String, List<int>?>{};
  final texts = <String, String>{};
  final readErrors = <String, String>{};
  for (final path in ToolchainFiles.all) {
    final file = File(p.joinAll([sdkRoot, ...path.split('/')]));
    try {
      final bytes = file.readAsBytesSync();
      inputs['sdk:$path'] = bytes;
      final text = utf8.decode(bytes, allowMalformed: true);
      texts[path] = text.startsWith('\uFEFF') ? text.substring(1) : text;
    } on FileSystemException catch (error) {
      inputs['sdk:$path'] = null;
      readErrors[path] = file.existsSync()
          ? fileErrorReason(error)
          : 'the file is missing';
    }
  }
  String text(String path) =>
      texts[path] ?? (throw ToolchainParseException(path, readErrors[path]!));

  final fallbackFile = notes.fileFor(flutterVersion);
  final fallbacks = <String>[];
  Sourced<T>? part<T>(
    String label,
    T Function() fromSdk,
    T Function(NotesFile file) fromNotes,
  ) {
    try {
      return Sourced(fromSdk(), ToolchainSource.sdk);
    } on ToolchainParseException catch (error) {
      final why = 'Appstein could not read it from the Flutter SDK ($error)';
      if (fallbackFile == null) {
        fallbacks.add(
          '$label: $why, and no curated notes cover Flutter $flutterVersion, '
          'so it is unknown.',
        );
        return null;
      }
      fallbacks.add(
        '$label: $why, so it comes from the curated notes for Flutter '
        '${fallbackFile.flutter}.',
      );
      return Sourced(fromNotes(fallbackFile), ToolchainSource.notes);
    }
  }

  return ToolchainReading(
    Toolchain(
      android: part('Android', () {
        final facts = parseGradleUtils(text(ToolchainFiles.gradleUtils));
        return AndroidToolchain(
          template: facts.template,
          flutterMinimums: facts.flutterMinimums,
          buildChecks: parseGradlePluginChecks(
            text(ToolchainFiles.gradlePluginChecks),
          ),
          maxKnown: facts.maxKnown,
          javaGradle: facts.javaGradle,
          javaAgp: facts.javaAgp,
        );
      }, (file) => file.android),
      ios: part(
        'iOS',
        () => AppleToolchain(
          deploymentTarget: parseDeploymentTarget(
            text(ToolchainFiles.iosTemplate),
            setting: 'IPHONEOS_DEPLOYMENT_TARGET',
            file: ToolchainFiles.iosTemplate,
          ),
        ),
        (file) => file.ios,
      ),
      macos: part(
        'macOS',
        () => AppleToolchain(
          deploymentTarget: parseDeploymentTarget(
            text(ToolchainFiles.macosTemplate),
            setting: 'MACOSX_DEPLOYMENT_TARGET',
            file: ToolchainFiles.macosTemplate,
          ),
        ),
        (file) => file.macos,
      ),
      fallbacks: fallbacks,
      stores: notes.stores,
      notes: notes.notesFor(
        flutterVersion,
        areas: const {NoteArea.android, NoteArea.ios, NoteArea.tooling},
      ),
    ),
    inputs,
  );
}
