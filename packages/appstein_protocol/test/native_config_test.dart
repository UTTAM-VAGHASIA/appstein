import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  NativeConfig sample() => NativeConfig({
    'android': NativeGroup({
      'app': NativeGroup({
        'minSdk': const NativeValue.found(
          24,
          at: 'android/app/build.gradle.kts:22',
          expression: 'flutter.minSdkVersion',
          resolvedFrom: 'flutter',
        ),
        'ndkVersion': const NativeValue.unknown(
          'computed in Gradle code: `findNdk()`',
          at: 'android/app/build.gradle.kts:10',
        ),
        'plugins': const NativeValue.found([
          'com.android.application',
          'dev.flutter.flutter-gradle-plugin',
        ], at: 'android/app/build.gradle.kts:2'),
        'flavors': NativeList([
          NativeEntry('prod', const {}, at: 'android/app/build.gradle.kts:30'),
          NativeEntry('dev', {
            'applicationIdSuffix': const NativeValue.found(
              '.dev',
              at: 'android/app/build.gradle.kts:27',
            ),
          }, at: 'android/app/build.gradle.kts:26'),
        ]),
      }),
    }),
    'ios': const NativeValue.absent('no ios/ folder'),
  });

  test('a value writes only the fields it has', () {
    expect(const NativeValue.found(true).toJson(), {
      'status': 'found',
      'value': true,
    });
    expect(const NativeValue.absent('no ios/ folder').toJson(), {
      'status': 'absent',
      'reason': 'no ios/ folder',
    });
    expect(const NativeValue.error('StateError').toJson(), {
      'status': 'error',
      'errorType': 'StateError',
    });
  });

  test('a list is sorted by name and its entries carry name and at', () {
    final json = sample().toJson();
    final flavors =
        ((json['android']! as Map)['app']! as Map)['flavors']! as List;
    expect(flavors, [
      {
        'name': 'dev',
        'at': 'android/app/build.gradle.kts:26',
        'applicationIdSuffix': {
          'status': 'found',
          'value': '.dev',
          'at': 'android/app/build.gradle.kts:27',
        },
      },
      {'name': 'prod', 'at': 'android/app/build.gradle.kts:30'},
    ]);
  });

  test('reads back what it wrote, ignoring meta', () {
    final json = sample().toJson();
    final read = NativeConfig.fromJson({
      ...json,
      'meta': {'inputHash': 'h'},
    });
    expect(read.toJson(), json);
    expect(read.sections.keys, ['android', 'ios']);
  });

  test('lookup walks groups and list entries by name', () {
    final config = sample();
    final minSdk = config.lookup(['android', 'app', 'minSdk'])! as NativeValue;
    expect(minSdk.value, 24);
    expect(minSdk.expression, 'flutter.minSdkVersion');
    final suffix =
        config.lookup([
              'android',
              'app',
              'flavors',
              'dev',
              'applicationIdSuffix',
            ])!
            as NativeValue;
    expect(suffix.value, '.dev');
    expect(config.lookup(['android', 'app', 'flavors', 'staging']), isNull);
    expect(config.lookup(['ios', 'infoPlist']), isNull);
    expect(config.lookup([]), isNull);
  });

  test('a group or an entry cannot use the keys that mark a value or an '
      'entry', () {
    expect(
      () => NativeGroup({'status': const NativeValue.found(1)}),
      throwsArgumentError,
    );
    for (final key in ['name', 'at', 'status']) {
      expect(
        () => NativeEntry('x', {key: const NativeValue.found(1)}),
        throwsArgumentError,
        reason: key,
      );
    }
  });

  test('malformed parts are a FormatException naming native.json', () {
    for (final bad in <Object?>[
      {'status': 'maybe'},
      {'status': 'found', 'value': 1.5},
      {
        'status': 'found',
        'value': <Object?>[1],
      },
      {'status': 'unknown'},
      [1],
      [<String, Object?>{}],
      'text',
      [
        {
          'name': 'x',
          'status': {'status': 'absent', 'reason': 'r'},
        },
      ],
      [
        {'name': 'x', 'status': 'found'},
      ],
    ]) {
      expect(
        () => NativeConfig.fromJson({'android': bad}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            startsWith('native.json:'),
          ),
        ),
        reason: '$bad',
      );
    }
  });

  test('an error section round-trips through fromJson', () {
    final json = NativeConfig({
      'android': const NativeValue.error('StateError'),
    }).toJson();
    final read = NativeConfig.fromJson(json);
    final node = read.sections['android']! as NativeValue;
    expect(node.status, NativeStatus.error);
    expect(node.errorType, 'StateError');
    expect(read.toJson(), json);
  });

  test('native.json is a map file but not one built from the analysis', () {
    expect(MapFiles.native, 'map/native.json');
    expect(MapFiles.all, isNot(contains(MapFiles.native)));
  });
}
