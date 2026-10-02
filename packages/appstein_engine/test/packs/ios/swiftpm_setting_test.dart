import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/src/packs/ios/swiftpm_setting.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../support/temp.dart';

void main() {
  NativeValue decide({
    String pubspec = 'name: app\n',
    Object? global,
    String? variable,
    String flutter = '3.47.5',
    String channel = 'stable',
  }) => swiftPackageManagerEnabled(
    pubspec: loadYamlNode(pubspec) as YamlMap,
    global: global,
    variable: variable,
    flutterVersion: flutter,
    channel: channel,
  );

  test('the default: on from 3.44, off before on stable, unknown before on '
      'other channels', () {
    expect(decide().toJson(), {
      'status': 'found',
      'value': true,
      'resolvedFrom': 'default',
      'note': 'on by default since Flutter 3.44',
    });
    expect(decide(flutter: '3.44.0').value, isTrue);
    expect(decide(flutter: '3.41.6').value, isFalse);
    expect(
      decide(flutter: '3.41.6', channel: 'beta').status,
      NativeStatus.unknown,
    );
    expect(decide(flutter: 'not-a-version').status, NativeStatus.unknown);
  });

  test("the environment: only 'true' turns it on, as in Flutter", () {
    expect(decide(variable: 'TRUE').value, isTrue);
    expect(decide(variable: '1').value, isFalse);
    expect(decide(variable: '').value, isFalse);
    expect(
      decide(variable: 'false').toJson(),
      containsPair('resolvedFrom', 'FLUTTER_SWIFT_PACKAGE_MANAGER'),
    );
  });

  test(
    'the global setting beats the environment; a non-boolean is unknown',
    () {
      expect(decide(global: false, variable: 'true').toJson(), {
        'status': 'found',
        'value': false,
        'resolvedFrom': 'flutter config (global)',
      });
      expect(decide(global: 'yes').status, NativeStatus.unknown);
    },
  );

  test("pubspec.yaml's flutter: config: beats everything, with its line", () {
    const pubspec =
        'name: app\nflutter:\n  config:\n    enable-swift-package-manager: false\n';
    expect(decide(pubspec: pubspec, global: true, variable: 'true').toJson(), {
      'status': 'found',
      'value': false,
      'at': 'pubspec.yaml:4',
      'resolvedFrom': 'pubspec.yaml',
    });
    expect(
      decide(
        pubspec:
            'name: app\nflutter:\n  config:\n    enable-swift-package-manager:\n',
      ).value,
      isTrue,
      reason: 'a null value falls through, as in Flutter',
    );
    expect(
      decide(pubspec: 'name: app\nflutter:\n  config: 3\n').toJson(),
      containsPair('status', 'unknown'),
    );
    expect(
      decide(
        pubspec:
            'name: app\nflutter:\n  config:\n    enable-swift-package-manager: maybe\n',
      ).reason,
      contains('must be true or false'),
    );
  });

  test('rawVariable keeps empty values, and Windows names ignore case', () {
    final windows = fakeEnvironment({
      'flutter_swift_package_manager': '',
    }, os: HostOs.windows);
    expect(rawVariable(windows, swiftPackageManagerVariable), '');
    final linux = fakeEnvironment({
      'flutter_swift_package_manager': 'true',
    }, os: HostOs.linux);
    expect(rawVariable(linux, swiftPackageManagerVariable), isNull);
  });
}
