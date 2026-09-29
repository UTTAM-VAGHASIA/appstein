import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';
import 'fvm_pin.dart';

/// Where a Flutter SDK was found.
enum SdkSource {
  /// Pinned by the project with FVM.
  fvm('FVM'),

  /// The FLUTTER_ROOT environment variable.
  flutterRoot('FLUTTER_ROOT'),

  /// The `flutter` command on PATH.
  path('PATH');

  const SdkSource(this.label);

  /// How the source is shown to people.
  final String label;
}

/// A Flutter SDK folder, and how it was found.
final class SdkLocation {
  /// Creates a location.
  const SdkLocation({
    required this.root,
    required this.source,
    this.fvmVersion,
  });

  /// The SDK folder (the one that contains `bin/flutter`).
  final String root;

  /// How it was found.
  final SdkSource source;

  /// The FVM-pinned version, when [source] is [SdkSource.fvm].
  final String? fvmVersion;
}

/// The result of looking for a project's Flutter SDK: a location, or a
/// problem with a fix.
final class SdkLookup {
  /// The SDK was found.
  const SdkLookup.found(SdkLocation this.location)
    : problem = null,
      fixHint = null;

  /// No usable SDK. [problem] says why, and [fixHint] says what to do.
  const SdkLookup.failed(String this.problem, String this.fixHint)
    : location = null;

  /// The SDK, when found.
  final SdkLocation? location;

  /// Why no SDK was found.
  final String? problem;

  /// What the user should do about it.
  final String? fixHint;
}

/// Finds the Flutter SDK a project uses, in the same order a developer's own
/// tools would:
/// 1. the project's FVM pin (the `.fvm/flutter_sdk` link, else FVM's cache,
///    which is `FVM_CACHE_PATH` or `~/fvm`);
/// 2. the FLUTTER_ROOT environment variable;
/// 3. the `flutter` command on PATH.
final class FlutterSdkLocator {
  /// Creates a locator for [environment].
  const FlutterSdkLocator(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  /// Finds the SDK for [projectRoot], or for no project when it is null.
  SdkLookup locate({String? projectRoot}) {
    if (projectRoot != null) {
      final FvmPin? pin;
      try {
        pin = readFvmPin(projectRoot);
      } on FormatException catch (error) {
        return SdkLookup.failed(
          'Could not read the FVM pin: ${error.message}',
          'Fix the file, or run `fvm use <version>` again.',
        );
      }
      if (pin != null) return _locateFvm(projectRoot, pin);
    }
    final flutterRoot = environment.variable('FLUTTER_ROOT');
    if (flutterRoot != null && _isSdk(flutterRoot)) {
      return SdkLookup.found(
        SdkLocation(root: flutterRoot, source: SdkSource.flutterRoot),
      );
    }
    final flutter = findExecutable('flutter', environment);
    if (flutter != null) {
      final root = p.dirname(p.dirname(resolveLinks(flutter)));
      if (_isSdk(root)) {
        return SdkLookup.found(SdkLocation(root: root, source: SdkSource.path));
      }
    }
    return const SdkLookup.failed(
      'No Flutter SDK found: the project has no FVM pin, FLUTTER_ROOT is not '
          'set, and `flutter` is not on PATH.',
      'Install Flutter (https://docs.flutter.dev/get-started/install), or pin '
          'a version in the project with `fvm use <version>`.',
    );
  }

  SdkLookup _locateFvm(String projectRoot, FvmPin pin) {
    final link = p.join(projectRoot, '.fvm', 'flutter_sdk');
    if (_isSdk(link)) {
      return SdkLookup.found(
        SdkLocation(
          root: resolveLinks(link),
          source: SdkSource.fvm,
          fvmVersion: pin.version,
        ),
      );
    }
    final home = environment.homeDir;
    final cache =
        environment.variable('FVM_CACHE_PATH') ??
        (home == null ? null : p.join(home, 'fvm'));
    if (cache != null) {
      final root = p.join(cache, 'versions', pin.version);
      if (_isSdk(root)) {
        return SdkLookup.found(
          SdkLocation(
            root: root,
            source: SdkSource.fvm,
            fvmVersion: pin.version,
          ),
        );
      }
    }
    return SdkLookup.failed(
      'The project pins Flutter ${pin.version} with FVM (${pin.configPath}), '
          'but that version is not installed.',
      'Run `fvm install ${pin.version}` in the project folder.',
    );
  }

  bool _isSdk(String root) {
    final flutter = environment.os == HostOs.windows
        ? 'flutter.bat'
        : 'flutter';
    return File(p.join(root, 'bin', flutter)).existsSync() &&
        Directory(p.join(root, 'packages', 'flutter')).existsSync();
  }
}
