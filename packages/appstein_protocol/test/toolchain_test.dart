import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const threshold = VersionThreshold(warnBelow: '9.1.0', errorBelow: '8.14.0');
  const android = AndroidToolchain(
    template: AndroidTemplate(
      gradle: '9.3.1',
      agp: '9.1.0',
      kgp: '2.4.0',
      ndk: '28.2.13676358',
      compileSdk: 36,
      targetSdk: 36,
      minSdk: 24,
    ),
    flutterMinimums: AndroidMinimums(
      compileSdk: 36,
      buildTools: '28.0.3',
      java: VersionThreshold(warnBelow: '17.0.0', errorBelow: '17.0.0'),
    ),
    buildChecks: AndroidBuildChecks(
      gradle: threshold,
      agp: VersionThreshold(warnBelow: '9.0.1', errorBelow: '8.11.1'),
      kgp: VersionThreshold(warnBelow: '2.3.20', errorBelow: '2.2.20'),
      java: VersionThreshold(warnBelow: '17', errorBelow: '17'),
      minSdk: VersionThreshold(warnBelow: '24', errorBelow: '23'),
    ),
    maxKnown: AndroidMaxKnown(
      gradle: '9.3.1',
      kgp: '2.4.0',
      agp: '9.2',
      agpWithFullKotlinSupport: '9.1.0',
    ),
    javaGradle: [
      JavaGradleCompat(javaMin: '25', javaMax: '26', gradleMin: '9.1.0'),
      JavaGradleCompat(
        javaMin: '16',
        javaMax: '17',
        gradleMin: '7.0',
        gradleMax: '8.14.100',
      ),
    ],
    javaAgp: [
      JavaAgpCompat(
        javaMin: '17',
        javaDefault: '17',
        agpMin: '8.0',
        agpMax: '9.2',
      ),
    ],
  );
  const note = CuratedNote(
    id: 'ios-minimum-15',
    since: '3.47',
    priority: 1,
    area: NoteArea.ios,
    summary: 'iOS 15 is the minimum.',
    use: 'IPHONEOS_DEPLOYMENT_TARGET = 15.0',
    avoid: '13.0',
    source: 'https://docs.flutter.dev/reference/supported-platforms',
  );
  const stores = StoreRequirements(
    play: {
      'targetSdk': [
        StoreRequirement(
          value: '36',
          since: '2026-08-31',
          summary: 'New apps and updates must target API level 36.',
          source:
              'https://developer.android.com/google/play/requirements/target-sdk',
        ),
      ],
    },
    appStore: {
      'xcode': [
        StoreRequirement(
          value: '27',
          since: '2027-04',
          formFactor: 'iphone',
          summary: 'Uploads must be built with the iOS 27 SDK.',
          source: 'https://developer.apple.com/news/?id=k1mtkt1k',
        ),
      ],
    },
  );
  const toolchain = Toolchain(
    android: Sourced(android, ToolchainSource.sdk),
    ios: Sourced(AppleToolchain(deploymentTarget: '15.0'), ToolchainSource.sdk),
    macos: Sourced(
      AppleToolchain(deploymentTarget: '12.0'),
      ToolchainSource.notes,
    ),
    fallbacks: ['macOS: the template could not be read.'],
    stores: stores,
    notes: [note],
  );

  test('writes the toolchain.json shape', () {
    final json = toolchain.toJson();
    final androidJson = json['android']! as Map<String, Object?>;
    expect(androidJson['source'], 'sdk');
    expect(androidJson['template'], {
      'gradle': '9.3.1',
      'agp': '9.1.0',
      'kgp': '2.4.0',
      'ndk': '28.2.13676358',
      'compileSdk': 36,
      'targetSdk': 36,
      'minSdk': 24,
    });
    expect((androidJson['javaGradle']! as List<Object?>).first, {
      'javaMin': '25',
      'javaMax': '26',
      'gradleMin': '9.1.0',
      'gradleMax': null,
    });
    expect(json['macos'], {'deploymentTarget': '12.0', 'source': 'notes'});
    expect(json['fallbacks'], ['macOS: the template could not be read.']);
    expect(
      ((json['stores']! as Map<String, Object?>)['play']!
          as Map<String, Object?>)['targetSdk'],
      [
        {
          'value': '36',
          'since': '2026-08-31',
          'formFactor': null,
          'summary': 'New apps and updates must target API level 36.',
          'source':
              'https://developer.android.com/google/play/requirements/target-sdk',
        },
      ],
    );
  });

  test('round-trips through JSON', () {
    final json = toolchain.toJson();
    expect(Toolchain.fromJson(json).toJson(), json);
  });

  test('a missing part is null and stays null', () {
    const empty = Toolchain(
      fallbacks: ['Android: unknown.'],
      stores: StoreRequirements(play: {}, appStore: {}),
      notes: [],
    );
    final json = empty.toJson();
    expect(json['android'], isNull);
    final back = Toolchain.fromJson(json);
    expect(back.android, isNull);
    expect(back.toJson(), json);
  });

  test('an unknown source is a FormatException', () {
    final json = toolchain.toJson();
    (json['ios']! as Map<String, Object?>)['source'] = 'guess';
    expect(() => Toolchain.fromJson(json), throwsFormatException);
  });

  test('AndroidToolchain.fromJson ignores a source key', () {
    final json = {...android.toJson(), 'source': 'notes'};
    expect(AndroidToolchain.fromJson(json).toJson(), android.toJson());
  });
}
