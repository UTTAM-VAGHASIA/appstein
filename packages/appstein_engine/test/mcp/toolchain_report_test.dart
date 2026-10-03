import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  const android = AndroidToolchain(
    template: AndroidTemplate(
      gradle: '8.14',
      agp: '8.11.1',
      kgp: '2.2.20',
      ndk: '28.2.13676358',
      compileSdk: 36,
      targetSdk: 36,
      minSdk: 24,
    ),
    flutterMinimums: AndroidMinimums(
      compileSdk: 34,
      buildTools: '34.0.0',
      java: VersionThreshold(warnBelow: '17', errorBelow: '11'),
    ),
    buildChecks: AndroidBuildChecks(
      gradle: VersionThreshold(warnBelow: '8.7.0', errorBelow: '8.3.0'),
      agp: VersionThreshold(warnBelow: '8.6.0', errorBelow: '8.1.1'),
      kgp: VersionThreshold(warnBelow: '2.1.0', errorBelow: '1.8.10'),
      java: VersionThreshold(warnBelow: '17', errorBelow: '11'),
      minSdk: VersionThreshold(warnBelow: '24', errorBelow: '21'),
    ),
    maxKnown: AndroidMaxKnown(
      gradle: '9.3.1',
      kgp: '2.4.0',
      agp: '9.1.0',
      agpWithFullKotlinSupport: '9.0.0',
    ),
    javaGradle: [],
    javaAgp: [],
  );
  const toolchain = Toolchain(
    android: Sourced(android, ToolchainSource.sdk),
    ios: Sourced(AppleToolchain(deploymentTarget: '15.0'), ToolchainSource.sdk),
    fallbacks: [],
    stores: StoreRequirements(play: {}, appStore: {}),
    notes: [],
  );
  final native = NativeConfig({
    'android': NativeGroup({
      'gradle': NativeGroup({
        'version': const NativeValue.found(
          '8.2',
          at: 'android/gradle/wrapper/gradle-wrapper.properties:5',
        ),
      }),
      'settings': NativeGroup({
        'agp': const NativeValue.found(
          '8.5.0',
          at: 'android/settings.gradle.kts:22',
        ),
        'kgp': const NativeValue.found(
          '2.5.0',
          at: 'android/settings.gradle.kts:23',
        ),
      }),
      'app': NativeGroup({
        'compileSdk': const NativeValue.found(
          33,
          at: 'android/app/build.gradle.kts:9',
        ),
        'targetSdk': const NativeValue.found(
          36,
          at: 'android/app/build.gradle.kts:23',
        ),
        'minSdk': const NativeValue.unknown('set conditionally'),
        'ndkVersion': const NativeValue.absent('not set'),
      }),
    }),
    'ios': NativeGroup({
      'xcode': NativeGroup({
        'configurations': NativeList([
          NativeEntry('Debug', {
            'deploymentTarget': const NativeValue.found('13.0'),
          }),
          NativeEntry('Release', {
            'deploymentTarget': const NativeValue.found('15.0'),
          }),
        ]),
      }),
    }),
  });

  test('compareVersions pads missing parts and ignores suffixes', () {
    expect(compareVersions('8.13', '8.13.0'), 0);
    expect(compareVersions('8.2', '8.13'), lessThan(0));
    expect(compareVersions('9.0.0-rc1', '9.0.0'), 0);
    expect(compareVersions('24', '21'), greaterThan(0));
    expect(compareVersions('JavaVersion.VERSION_17', '17'), isNull);
  });

  test("each mismatch against Flutter's own thresholds", () {
    final reply = toolchainInfo(toolchain, native) as ToolReply;
    final mismatches = (reply.result['mismatches']! as List)
        .cast<Map<String, Object?>>();
    expect(
      [for (final m in mismatches) (m['name'], m['severity'], m['limit'])],
      [
        ('Gradle', 'error', '8.3.0'),
        ('AGP', 'warning', '8.6.0'),
        ('KGP', 'warning', '2.4.0'),
        ('compileSdk', 'warning', '34'),
        ('iOS deployment target (Debug)', 'warning', '15.0'),
      ],
    );
    expect(
      mismatches.first['message'],
      "Gradle 8.2 is below 8.3.0, where Flutter's Gradle plugin fails the "
      'build.',
    );
    expect(
      mismatches.first['at'],
      'android/gradle/wrapper/gradle-wrapper.properties:5',
    );
    expect(
      mismatches[2]['message'],
      'KGP 2.5.0 is newer than 2.4.0, the newest this Flutter knows.',
    );
    expect(reply.result['notComparable'], [
      {'name': 'minSdk', 'reason': 'set conditionally'},
    ]);
    expect(
      reply.summary,
      "5 mismatches between the project's native config and this Flutter's "
      'toolchain: 1 error, 4 warnings. 1 value could not be compared.',
    );
    expectMatchesSchema(
      ToolSchemas.toolchainResult,
      withoutNulls(reply.result),
    );
  });

  test('the current values are listed with where they were found', () {
    final reply = toolchainInfo(toolchain, native) as ToolReply;
    final current = (reply.result['current']! as List)
        .cast<Map<String, Object?>>();
    expect(
      [for (final c in current) c['name']],
      [
        'Gradle',
        'AGP',
        'KGP',
        'compileSdk',
        'targetSdk',
        'minSdk',
        'ndkVersion',
        'iOS deployment target (Debug)',
        'iOS deployment target (Release)',
      ],
    );
    expect(current[3], {
      'name': 'compileSdk',
      'status': 'found',
      'value': '33',
      'at': 'android/app/build.gradle.kts:9',
    });
    expect(current[6]['status'], 'absent');
  });

  test('no native config: only the valid set, and the summary says why', () {
    final reply = toolchainInfo(toolchain, null) as ToolReply;
    expect(reply.result['current'], isEmpty);
    expect(reply.result['mismatches'], isEmpty);
    expect((reply.result['valid']! as Map).containsKey('android'), isTrue);
    expect(
      reply.summary,
      '`map/native.json` is missing, so only the versions that work with '
      'this Flutter are listed.',
    );
  });

  test('values within range are no mismatch', () {
    final fine = NativeConfig({
      'android': NativeGroup({
        'gradle': NativeGroup({'version': const NativeValue.found('8.14')}),
      }),
    });
    final reply = toolchainInfo(toolchain, fine) as ToolReply;
    expect(reply.result['mismatches'], isEmpty);
    expect(
      reply.summary,
      "The project's native values are within what this Flutter accepts.",
    );
  });
}
