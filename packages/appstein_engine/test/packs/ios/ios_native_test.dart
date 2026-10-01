import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/src/native/native_extractor.dart';
import 'package:appstein_engine/src/packs/ios/ios_native.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/native_support.dart';
import '../../support/temp.dart';

void main() {
  NativeValue value(NativeSection section, List<String> path) =>
      NativeConfig({'ios': section.node}).lookup(['ios', ...path])!
          as NativeValue;

  group('the template app', () {
    late NativeSection section;

    setUp(() => section = readIosNative(nativeContext(copyNativeTemplate())));

    test('Info.plist', () {
      expect(
        value(section, ['infoPlist', 'bundleIdentifier']).value,
        r'$(PRODUCT_BUNDLE_IDENTIFIER)',
      );
      expect(value(section, ['infoPlist', 'displayName']).value, 'Probe App');
      expect(value(section, ['infoPlist', 'bundleName']).value, 'probe_app');
      expect(value(section, ['infoPlist', 'sceneManifest']).value, isTrue);
      expect(
        value(section, ['infoPlist', 'sceneDelegate']).value,
        r'$(PRODUCT_MODULE_NAME).SceneDelegate',
      );
      expect(
        NativeConfig({
          'ios': section.node,
        }).lookup(['ios', 'infoPlist', 'usageDescriptions'])!.toJson(),
        <Object?>[],
      );
    });

    test('Xcode: the Runner configurations, with the deployment target '
        'inherited from the project', () {
      expect(value(section, ['xcode', 'swiftPackageIntegrated']).value, isTrue);
      final configurations = NativeConfig({
        'ios': section.node,
      }).lookup(['ios', 'xcode', 'configurations'])!;
      expect(
        [
          for (final entry in (configurations as NativeList).entries)
            entry.name,
        ],
        ['Debug', 'Profile', 'Release'],
      );
      final bundle = value(section, [
        'xcode',
        'configurations',
        'Debug',
        'bundleIdentifier',
      ]);
      expect(bundle.value, 'dev.sample.probeApp');
      expect(bundle.note, isNull);
      expect(bundle.at, startsWith('ios/Runner.xcodeproj/project.pbxproj:'));
      final target = value(section, [
        'xcode',
        'configurations',
        'Release',
        'deploymentTarget',
      ]);
      expect(target.value, '15.0');
      expect(target.note, 'set at project level');
      expect(
        value(section, [
          'xcode',
          'configurations',
          'Profile',
          'swiftVersion',
        ]).value,
        '5.0',
      );
      expect(
        value(section, [
          'xcode',
          'configurations',
          'Debug',
          'developmentTeamSet',
        ]).reason,
        'DEVELOPMENT_TEAM is not in project.pbxproj; it may come from an '
        '.xcconfig file',
      );
    });

    test('SwiftPM, the generated package, no Podfile', () {
      expect(
        value(section, ['swiftPackageManager', 'enabled']).toJson(),
        containsPair('resolvedFrom', 'default'),
      );
      expect(value(section, ['generatedPackage', 'iosVersion']).toJson(), {
        'status': 'found',
        'value': '15.0',
        'at':
            'ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/'
            'Package.swift:12',
      });
      expect(value(section, ['generatedPackage', 'plugins']).value, isEmpty);
      expect(value(section, ['podfile']).reason, startsWith('no ios/Podfile'));
    });

    test('the global setting and the variable are inputs', () {
      expect(
        section.inputs.keys,
        containsAll([
          'file:ios/Runner/Info.plist',
          'file:ios/Runner.xcodeproj/project.pbxproj',
          'file:ios/Podfile',
          'file:pubspec.yaml',
          'flutter-config:enable-swift-package-manager',
          'env:FLUTTER_SWIFT_PACKAGE_MANAGER',
        ]),
      );
    });
  });

  group('projects that are not the template', () {
    late String app;

    setUp(() {
      app = p.join(tempDir().path, 'other app');
      writeProjectFiles(app, {'pubspec.yaml': 'name: other\n'});
    });

    NativeSection read({Map<String, String> variables = const {}}) =>
        readIosNative(nativeContext(app, variables: variables));

    test('no ios folder: the whole section is absent', () {
      expect(readIosNative(nativeContext(tempDir().path)).node.toJson(), {
        'status': 'absent',
        'reason': 'no ios/ folder',
      });
    });

    test('usage descriptions, and the generated package before pub get', () {
      writeProjectFiles(app, {
        'ios/Runner/Info.plist':
            '<plist><dict>\n'
            '<key>NSPhotoLibraryUsageDescription</key>\n<string>Pick photos</string>\n'
            '<key>NSCameraUsageDescription</key>\n<string>Scan codes</string>\n'
            '</dict></plist>\n',
      });
      final section = read();
      expect(
        NativeConfig({
          'ios': section.node,
        }).lookup(['ios', 'infoPlist', 'usageDescriptions'])!.toJson(),
        [
          {
            'name': 'NSCameraUsageDescription',
            'at': 'ios/Runner/Info.plist:4',
            'text': {
              'status': 'found',
              'value': 'Scan codes',
              'at': 'ios/Runner/Info.plist:5',
            },
          },
          {
            'name': 'NSPhotoLibraryUsageDescription',
            'at': 'ios/Runner/Info.plist:2',
            'text': {
              'status': 'found',
              'value': 'Pick photos',
              'at': 'ios/Runner/Info.plist:3',
            },
          },
        ],
      );
      expect(
        value(section, ['infoPlist', 'sceneManifest']).status,
        NativeStatus.absent,
      );
      expect(
        value(section, ['generatedPackage']).reason,
        'not generated yet: `flutter pub get` writes it',
      );
    });

    test('a binary Info.plist, a JSON project and a project with no Runner', () {
      File(p.join(app, 'ios', 'Runner', 'Info.plist'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('bplist00');
      writeProjectFiles(app, {
        'ios/Runner.xcodeproj/project.pbxproj': '{"objects": {}}\n',
      });
      var section = read();
      expect(value(section, ['infoPlist']).reason, contains('binary'));
      expect(
        value(section, ['xcode', 'swiftPackageIntegrated']).value,
        isFalse,
      );
      expect(
        value(section, ['xcode', 'configurations']).reason,
        contains('expected "="'),
      );
      writeProjectFiles(app, {
        'ios/Runner.xcodeproj/project.pbxproj':
            '{\n objects = {\n  P = { isa = PBXProject; targets = (); };\n };\n'
            ' rootObject = P;\n}\n',
      });
      section = read();
      expect(
        value(section, ['xcode', 'configurations']).reason,
        'project.pbxproj has no Runner target',
      );
    });

    test('a binary Info.plist that is not UTF-8 is unknown, not a crash', () {
      File(p.join(app, 'ios', 'Runner', 'Info.plist'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xff, 0xfe]);
      final section = read();
      final plist = value(section, ['infoPlist']);
      expect(plist.status, NativeStatus.unknown);
      expect(plist.reason, contains('not valid UTF-8'));
      expect(section.inputs['file:ios/Runner/Info.plist'], isNotNull);
    });

    test("a Runner configuration's own settings, a team only as yes or no", () {
      writeProjectFiles(app, {
        'ios/Runner.xcodeproj/project.pbxproj': '''
{
	objects = {
		C1 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				DEVELOPMENT_TEAM = ABC123XYZ;
				PRODUCT_BUNDLE_IDENTIFIER = "\$(BASE_ID).app";
			};
			name = Debug;
		};
		L1 = { isa = XCConfigurationList; buildConfigurations = ( C1, ); };
		T1 = { isa = PBXNativeTarget; name = Runner; buildConfigurationList = L1; };
		P = { isa = PBXProject; targets = ( T1, ); };
	};
	rootObject = P;
}
''',
      });
      final section = read();
      final debug = ['xcode', 'configurations', 'Debug'];
      expect(value(section, [...debug, 'deploymentTarget']).toJson(), {
        'status': 'found',
        'value': '16.0',
        'at': 'ios/Runner.xcodeproj/project.pbxproj:6',
      });
      expect(value(section, [...debug, 'developmentTeamSet']).value, isTrue);
      expect(
        value(section, [...debug, 'bundleIdentifier']).note,
        'uses Xcode build variables',
      );
      expect(jsonEncode(section.node.toJson()), isNot(contains('ABC123XYZ')));
    });

    test('a Podfile version from a Ruby expression is unknown', () {
      writeProjectFiles(app, {
        'ios/Podfile':
            r'platform :ios, $iOSVersion'
            '\n',
      });
      expect(value(read(), ['podfile', 'platform']).toJson(), {
        'status': 'unknown',
        'reason': 'set by a Ruby expression',
        'at': 'ios/Podfile:1',
      });
      writeProjectFiles(app, {'ios/Podfile': 'platform :ios\n'});
      expect(
        value(read(), ['podfile', 'platform']).status,
        NativeStatus.absent,
      );
    });

    test('an unreadable pubspec.yaml leaves SwiftPM unknown; a missing one '
        'falls through', () {
      writeProjectFiles(app, {
        'ios/Runner/Info.plist': '<plist><dict/></plist>',
        'pubspec.yaml': 'name: [broken\n',
      });
      expect(value(read(), ['swiftPackageManager', 'enabled']).toJson(), {
        'status': 'unknown',
        'reason':
            "pubspec.yaml can't be read, and its `flutter: config:` decides "
            'first',
        'at': 'pubspec.yaml',
      });
      File(p.join(app, 'pubspec.yaml')).deleteSync();
      expect(
        value(read(), ['swiftPackageManager', 'enabled']).status,
        NativeStatus.found,
      );
    });

    test('the generated package reason follows the SwiftPM decision', () {
      writeProjectFiles(app, {
        'ios/Runner/Info.plist': '<plist><dict/></plist>',
        'pubspec.yaml':
            'name: other\nflutter:\n  config:\n    enable-swift-package-manager: false\n',
      });
      expect(
        value(read(), ['generatedPackage']).reason,
        "SwiftPM is off, so Flutter doesn't generate it",
      );
      writeProjectFiles(app, {'pubspec.yaml': 'name: [broken\n'});
      expect(
        value(read(), ['generatedPackage']).reason,
        '`flutter pub get` writes it when SwiftPM is on',
      );
    });

    test('no scene manifest at all says so', () {
      writeProjectFiles(app, {
        'ios/Runner/Info.plist': '<plist><dict/></plist>',
      });
      expect(
        value(read(), ['infoPlist', 'sceneDelegate']).reason,
        'no scene manifest in ios/Runner/Info.plist',
      );
    });

    test('a Runner target with no build configuration list is unknown', () {
      writeProjectFiles(app, {
        'ios/Runner.xcodeproj/project.pbxproj': '''
{
	objects = {
		T1 = { isa = PBXNativeTarget; name = Runner; buildConfigurationList = GONE; };
		P = { isa = PBXProject; targets = ( T1, ); };
	};
	rootObject = P;
}
''',
      });
      expect(
        value(read(), ['xcode', 'configurations']).reason,
        'the Runner target has no build configuration list',
      );
    });

    test('a Podfile with its lock, and plugins in the generated package', () {
      writeProjectFiles(app, {
        'ios/Podfile': "platform :ios, '13.0'\n",
        'ios/Podfile.lock': 'PODS:\n',
        'ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift':
            '.iOS("15.0")\n.package(name: "camera_avfoundation", path: "/Users/me/x")\n',
      });
      final section = read();
      expect(value(section, ['podfile', 'platform']).toJson(), {
        'status': 'found',
        'value': '13.0',
        'at': 'ios/Podfile:1',
      });
      expect(value(section, ['podfile', 'lockPresent']).value, isTrue);
      expect(value(section, ['generatedPackage', 'plugins']).value, [
        'camera_avfoundation',
      ]);
      expect(jsonEncode(section.node.toJson()), isNot(contains('/Users/me')));
    });

    test("the global settings file and the environment are read as Flutter "
        'reads them', () {
      writeProjectFiles(app, {
        'ios/Runner/Info.plist': '<plist><dict/></plist>',
      });
      final home = tempDir().path;
      File(
        p.join(home, '.flutter_settings'),
      ).writeAsStringSync('{"enable-swift-package-manager": false}');
      final global = read(variables: {'APPDATA': home, 'HOME': home});
      expect(value(global, ['swiftPackageManager', 'enabled']).toJson(), {
        'status': 'found',
        'value': false,
        'resolvedFrom': 'flutter config (global)',
      });
      expect(
        global.inputs['flutter-config:enable-swift-package-manager'],
        utf8.encode('false'),
      );
      final environment = read(
        variables: {'FLUTTER_SWIFT_PACKAGE_MANAGER': '1'},
      );
      expect(
        value(environment, ['swiftPackageManager', 'enabled']).value,
        isFalse,
      );
      expect(
        environment.inputs['env:FLUTTER_SWIFT_PACKAGE_MANAGER'],
        utf8.encode('1'),
      );
    });
  });
}
