import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';
import 'flutter_sdk_reader.dart';
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
    this.unmetFvmPin,
    this.notes = const [],
  });

  /// The SDK folder (the one that contains `bin/flutter`).
  final String root;

  /// How it was found.
  final SdkSource source;

  /// The version the project pins with FVM, when this SDK is the one FVM
  /// provides ([source] is [SdkSource.fvm]). It is null for an SDK found
  /// another way; see [unmetFvmPin] for a pin that such an SDK stands in for.
  final String? fvmVersion;

  /// The pin the project sets with FVM when FVM doesn't have it installed,
  /// so this SDK was found another way. `SdkInfo.fvmVersion` takes this
  /// value when the SDK meets the pin.
  final String? unmetFvmPin;

  /// Notes about what the lookup passed over on the way, such as a
  /// FLUTTER_ROOT that isn't an SDK. The Flutter check shows them.
  final List<String> notes;
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
///    found by [fvmCacheFolder]);
/// 2. the FLUTTER_ROOT environment variable;
/// 3. the `flutter` command on PATH.
///
/// A pin states which Flutter the project needs, and FVM is only one way to
/// install it. When the project pins one that FVM doesn't have, steps 2 and
/// 3 still run, and an SDK they find records the unmet pin in
/// [SdkLocation.unmetFvmPin]; the caller then checks that the SDK meets it.
/// A version pin (`3.47.5`, or `3.24.0@beta`, whose version is `3.24.0`) is
/// met by that version; a channel pin (`stable`) by an SDK on that channel.
/// Only when neither step finds an SDK does the lookup fail, naming every
/// source it tried.
///
/// The pin is looked up in the project folder and its parents, as FVM does.
/// FLUTTER_ROOT is preferred over PATH even when its version differs from
/// the pin; the caller then reports the mismatch. A FLUTTER_ROOT that isn't
/// an SDK is skipped with a note: Flutter's own launcher scripts set it
/// themselves, so a wrong value can only mislead this lookup.
final class FlutterSdkLocator {
  /// Creates a locator for [environment].
  const FlutterSdkLocator(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  static const _installHint =
      'Install Flutter (https://docs.flutter.dev/get-started/install), or '
      'pin a version in the project with `fvm use <version>`.';

  /// Finds the SDK for [projectRoot], or for no project when it is null.
  SdkLookup locate({String? projectRoot}) {
    FvmPin? unmetPin;
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
      if (pin != null) {
        final fvm = _locateFvm(pin);
        if (fvm != null) return SdkLookup.found(fvm);
        unmetPin = pin;
      }
    }
    final unmetVersion = unmetPin?.version;
    final notes = <String>[];
    final flutterRoot = environment.variable('FLUTTER_ROOT');
    if (flutterRoot != null) {
      if (_isSdk(flutterRoot)) {
        return SdkLookup.found(
          SdkLocation(
            root: flutterRoot,
            source: SdkSource.flutterRoot,
            unmetFvmPin: unmetVersion,
          ),
        );
      }
      notes.add(
        'FLUTTER_ROOT is set to $flutterRoot, which is not a Flutter SDK, so '
        'it was ignored.',
      );
    }
    final flutter = findExecutable('flutter', environment);
    if (flutter != null) {
      // A snap, Homebrew or asdf shim doesn't resolve to an SDK folder.
      final root = p.dirname(p.dirname(resolveLinks(flutter)));
      if (_isSdk(root)) {
        return SdkLookup.found(
          SdkLocation(
            root: root,
            source: SdkSource.path,
            unmetFvmPin: unmetVersion,
            notes: notes,
          ),
        );
      }
    }
    final tried = [
      if (unmetPin != null)
        "the project's FVM pin (${describeFvmPin(unmetPin.version)}, from "
            '${unmetPin.configPath}, not installed)'
      else if (projectRoot != null)
        'no FVM pin in the project',
      if (flutterRoot == null)
        'FLUTTER_ROOT (not set)'
      else
        'FLUTTER_ROOT (set to $flutterRoot, not an SDK)',
      if (flutter == null)
        '`flutter` on PATH (not found)'
      else
        '`flutter` on PATH (found at $flutter, not inside an SDK)',
    ];
    return SdkLookup.failed(
      'No Flutter SDK found. Tried: ${tried.join(', ')}.',
      unmetPin != null ? fvmInstallHint(unmetPin.version) : _installHint,
    );
  }

  /// The SDK FVM provides for [pin], or null when FVM doesn't have it.
  ///
  /// The `.fvm/flutter_sdk` link next to the pin is used unless it is stale:
  /// `.fvm/` is usually gitignored while the pin is committed, so a pulled pin
  /// bump leaves the link on the old version. A link whose SDK reports a
  /// version other than the pin is skipped, and FVM's cache is tried next.
  /// A link is kept when its SDK can't be read (so the caller reports it as
  /// not set up), and when the pin has no version to compare: a bare channel
  /// such as `stable`, or a git reference.
  SdkLocation? _locateFvm(FvmPin pin) {
    final link = p.join(pin.pinDirectory, '.fvm', 'flutter_sdk');
    if (_isSdk(link) && !_isStaleLink(link, pin)) {
      return SdkLocation(
        root: resolveLinks(link),
        source: SdkSource.fvm,
        fvmVersion: pin.version,
      );
    }
    final cache = fvmCacheFolder(pin, environment);
    if (cache != null) {
      final root = p.join(cache, 'versions', pin.version);
      if (_isSdk(root)) {
        return SdkLocation(
          root: root,
          source: SdkSource.fvm,
          fvmVersion: pin.version,
        );
      }
    }
    return null;
  }

  bool _isStaleLink(String link, FvmPin pin) {
    final version = pin.flutterVersion;
    if (version == null) return false;
    try {
      Version.parse(version);
    } on FormatException {
      return false;
    }
    try {
      return readSdkVersions(link).flutter != version;
    } on SdkNotSetUpException {
      return false;
    } on FormatException {
      return false;
    }
  }

  bool _isSdk(String root) {
    final flutter = environment.os == HostOs.windows
        ? 'flutter.bat'
        : 'flutter';
    return File(p.join(root, 'bin', flutter)).existsSync() &&
        Directory(p.join(root, 'packages', 'flutter')).existsSync();
  }
}
