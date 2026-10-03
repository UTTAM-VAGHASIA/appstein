import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// Compares two dotted version numbers, padding missing parts with 0 and
/// ignoring a `-` or `+` suffix (`9.0.0-rc1` counts as `9.0.0`). Null when
/// either isn't a version number.
int? compareVersions(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int>? _parts(String version) {
  final core = version.trim().split(RegExp('[-+]')).first;
  final parts = [for (final part in core.split('.')) int.tryParse(part)];
  return parts.isEmpty || parts.contains(null) ? null : parts.cast<int>();
}

/// `toolchain` (spec §8): the native versions that work with this Flutter
/// ([toolchain]), the project's current values from [native]
/// (`map/native.json`; null when it is missing), and the mismatches, using
/// only thresholds Flutter itself applies (spec §8, §12):
/// - Gradle, AGP and KGP below the version at which Flutter's Gradle plugin
///   fails the build: an error; below the one at which it warns: a warning;
///   above the newest this Flutter knows: a warning;
/// - minSdk below the build-check thresholds: an error or a warning;
/// - compileSdk below Flutter's minimum, and an iOS deployment target below
///   the SDK template's: a warning;
/// - a value `native.json` records as `unknown` is not comparable, with its
///   reason.
///
/// targetSdk and the NDK version are shown but have no Flutter threshold;
/// store minimums are in the valid set as the curated notes give them.
ToolAnswer toolchainInfo(Toolchain toolchain, NativeConfig? native) {
  final android = toolchain.android?.value;
  final ios = toolchain.ios?.value;
  final current = <Map<String, Object?>>[];
  final mismatches = <Map<String, Object?>>[];
  final notComparable = <Map<String, Object?>>[];

  void value(
    String name,
    List<String> path, {
    VersionThreshold? checks,
    String? maxKnown,
    String? minimum,
    String? minimumIs,
  }) {
    final node = native?.lookup(path);
    if (node is! NativeValue) return;
    final text = switch (node.value) {
      final List<String> list => list.join(', '),
      null => null,
      final other => '$other',
    };
    current.add({
      'name': name,
      'status': node.status.name,
      'value': ?text,
      'at': ?node.at,
      'expression': ?node.expression,
      'reason': ?node.reason,
    });
    switch (node.status) {
      case NativeStatus.absent:
        return;
      case NativeStatus.unknown:
      case NativeStatus.error:
        notComparable.add({
          'name': name,
          'reason':
              node.reason ?? 'its platform pack failed (${node.errorType})',
        });
        return;
      case NativeStatus.found:
        break;
    }
    void mismatch(String severity, String limit, String message) =>
        mismatches.add({
          'name': name,
          'severity': severity,
          'value': text!,
          'limit': limit,
          'message': message,
          'at': ?node.at,
        });
    final comparable = [?checks?.errorBelow, ?maxKnown, ?minimum];
    if (comparable.isNotEmpty &&
        compareVersions(text!, comparable.first) == null) {
      notComparable.add({
        'name': name,
        'reason': '"$text" is not a version number',
      });
      return;
    }
    if (checks != null) {
      if (compareVersions(text!, checks.errorBelow)! < 0) {
        mismatch(
          'error',
          checks.errorBelow,
          "$name $text is below ${checks.errorBelow}, where Flutter's Gradle "
              'plugin fails the build.',
        );
      } else if (compareVersions(text, checks.warnBelow)! < 0) {
        mismatch(
          'warning',
          checks.warnBelow,
          "$name $text is below ${checks.warnBelow}, where Flutter's Gradle "
              'plugin warns.',
        );
      }
    }
    if (maxKnown != null && compareVersions(text!, maxKnown)! > 0) {
      mismatch(
        'warning',
        maxKnown,
        '$name $text is newer than $maxKnown, the newest this Flutter knows.',
      );
    }
    if (minimum != null && compareVersions(text!, minimum)! < 0) {
      mismatch(
        'warning',
        minimum,
        '$name $text is below $minimum, $minimumIs.',
      );
    }
  }

  value(
    'Gradle',
    ['android', 'gradle', 'version'],
    checks: android?.buildChecks.gradle,
    maxKnown: android?.maxKnown.gradle,
  );
  value(
    'AGP',
    ['android', 'settings', 'agp'],
    checks: android?.buildChecks.agp,
    maxKnown: android?.maxKnown.agp,
  );
  value(
    'KGP',
    ['android', 'settings', 'kgp'],
    checks: android?.buildChecks.kgp,
    maxKnown: android?.maxKnown.kgp,
  );
  value(
    'compileSdk',
    ['android', 'app', 'compileSdk'],
    minimum: android == null ? null : '${android.flutterMinimums.compileSdk}',
    minimumIs: "Flutter's minimum",
  );
  value('targetSdk', ['android', 'app', 'targetSdk']);
  value('minSdk', [
    'android',
    'app',
    'minSdk',
  ], checks: android?.buildChecks.minSdk);
  value('ndkVersion', ['android', 'app', 'ndkVersion']);
  if (native?.lookup(['ios', 'xcode', 'configurations']) case NativeList(
    :final entries,
  )) {
    for (final entry in entries) {
      value(
        'iOS deployment target (${entry.name})',
        ['ios', 'xcode', 'configurations', entry.name, 'deploymentTarget'],
        minimum: ios?.deploymentTarget,
        minimumIs: "the SDK template's",
      );
    }
  }

  final valid = toolchain.toJson()..remove('notes');
  final errors = mismatches.where((m) => m['severity'] == 'error').length;
  final warnings = mismatches.length - errors;
  String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  final summary = native == null
      ? '`map/native.json` is missing, so only the versions that work with '
            'this Flutter are listed.'
      : [
          if (mismatches.isEmpty)
            "The project's native values are within what this Flutter "
                'accepts.'
          else
            '${plural(mismatches.length, 'mismatch', 'mismatches')} between '
                "the project's native config and this Flutter's toolchain: "
                '${plural(errors, 'error', 'errors')}, '
                '${plural(warnings, 'warning', 'warnings')}.',
          if (notComparable.isNotEmpty)
            '${plural(notComparable.length, 'value', 'values')} could not be '
                'compared.',
        ].join(' ');
  return ToolReply({
    'valid': valid,
    'notes': [for (final note in toolchain.notes) note.toJson()],
    'current': current,
    'mismatches': mismatches,
    'notComparable': notComparable,
  }, summary);
}
