import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/flutter_fixtures.dart';
import '../support/temp.dart';

void main() {
  final notes = CuratedNotes.bundled();

  String sdkWith(String version) {
    final root = p.join(tempDir().path, 'flutter sdk');
    addToolchainFiles(root, version);
    return root;
  }

  File sdkFile(String root, String path) =>
      File(p.joinAll([root, ...path.split('/')]));

  test('reads every part from a 3.47.5 SDK, with no fallback', () {
    final reading = readToolchain(
      sdkWith('3.47.5'),
      flutterVersion: '3.47.5',
      notes: notes,
    );
    final toolchain = reading.toolchain;
    expect(toolchain.android?.source, ToolchainSource.sdk);
    expect(toolchain.android?.value.template.agp, '9.1.0');
    expect(toolchain.android?.value.buildChecks.gradle.errorBelow, '8.14.0');
    expect(toolchain.ios?.source, ToolchainSource.sdk);
    expect(toolchain.ios?.value.deploymentTarget, '15.0');
    expect(toolchain.macos?.value.deploymentTarget, '12.0');
    expect(toolchain.fallbacks, isEmpty);
    expect(toolchain.stores.toJson(), notes.stores.toJson());
    final ids = [for (final note in toolchain.notes) note.id];
    expect(ids, contains('ios-minimum-15'));
    expect(ids, isNot(contains('dot-shorthands')));
    expect(
      reading.inputs.keys,
      unorderedEquals([for (final path in ToolchainFiles.all) 'sdk:$path']),
    );
    expect(reading.inputs.values.every((bytes) => bytes != null), isTrue);
  });

  // The fallback matrix in each notes file must equal what Flutter's own
  // files say, or a fallback would hand agents wrong versions.
  for (final version in fixtureFlutterVersions) {
    test('the notes fallback for $version matches its SDK files', () {
      final read = readToolchain(
        sdkWith(version),
        flutterVersion: version,
        notes: notes,
      ).toolchain;
      final file = notes.fileFor(version)!;
      expect(read.android!.value.toJson(), file.android.toJson());
      expect(read.ios!.value.toJson(), file.ios.toJson());
      expect(read.macos!.value.toJson(), file.macos.toJson());
    });
  }

  test('reads CRLF SDK files exactly as LF ones (Review Focus 1)', () {
    final root = sdkWith('3.47.5');
    for (final path in ToolchainFiles.all) {
      final file = sdkFile(root, path);
      file.writeAsStringSync(
        file
            .readAsStringSync()
            .replaceAll('\r\n', '\n')
            .replaceAll('\n', '\r\n'),
      );
    }
    final crlf = readToolchain(root, flutterVersion: '3.47.5', notes: notes);
    final lf = readToolchain(
      sdkWith('3.47.5'),
      flutterVersion: '3.47.5',
      notes: notes,
    );
    expect(crlf.toolchain.toJson(), lf.toolchain.toJson());
  });

  group('falls back to the notes (Review Focus 2)', () {
    test('for Android when gradle_utils.dart is missing', () {
      final root = sdkWith('3.47.5');
      sdkFile(root, ToolchainFiles.gradleUtils).deleteSync();
      final reading = readToolchain(
        root,
        flutterVersion: '3.47.5',
        notes: notes,
      );
      final toolchain = reading.toolchain;
      expect(toolchain.android?.source, ToolchainSource.notes);
      expect(
        toolchain.android?.value.toJson(),
        notes.fileFor('3.47.5')!.android.toJson(),
      );
      expect(toolchain.ios?.source, ToolchainSource.sdk);
      expect(toolchain.fallbacks, [
        'Android: Appstein could not read it from the Flutter SDK '
            '(gradle_utils.dart: the file is missing), so it comes from the '
            'curated notes for Flutter 3.47.',
      ]);
      expect(reading.inputs['sdk:${ToolchainFiles.gradleUtils}'], isNull);
    });

    test('for Android when the Gradle plugin checks are reshaped', () {
      final root = sdkWith('3.47.5');
      sdkFile(root, ToolchainFiles.gradlePluginChecks).writeAsStringSync('');
      final toolchain = readToolchain(
        root,
        flutterVersion: '3.47.5',
        notes: notes,
      ).toolchain;
      expect(toolchain.android?.source, ToolchainSource.notes);
      expect(
        toolchain.fallbacks.single,
        contains('DependencyVersionChecker.kt'),
      );
    });

    test('from the newest notes at or below a newer SDK', () {
      final root = p.join(tempDir().path, 'empty sdk');
      final toolchain = readToolchain(
        root,
        flutterVersion: '3.50.1',
        notes: notes,
      ).toolchain;
      expect(toolchain.android?.source, ToolchainSource.notes);
      expect(toolchain.macos?.value.deploymentTarget, '12.0');
      expect(toolchain.fallbacks, hasLength(3));
      expect(
        toolchain.fallbacks.first,
        contains('curated notes for Flutter 3.47'),
      );
    });

    test('to nothing for an SDK older than every notes file', () {
      final root = p.join(tempDir().path, 'empty sdk');
      final toolchain = readToolchain(
        root,
        flutterVersion: '3.38.6',
        notes: notes,
      ).toolchain;
      expect(toolchain.android, isNull);
      expect(toolchain.ios, isNull);
      expect(toolchain.macos, isNull);
      expect(
        toolchain.fallbacks.first,
        'Android: Appstein could not read it from the Flutter SDK '
        '(gradle_utils.dart: the file is missing), and no curated notes '
        'cover Flutter 3.38.6, so it is unknown.',
      );
    });
  });
}
