import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/src/native/native_extractor.dart';
import 'package:appstein_engine/src/packs/android/android_native.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';
import '../../support/native_support.dart';
import '../../support/temp.dart';

void main() {
  late Sourced<AndroidToolchain> flutter;

  setUpAll(() => flutter = flutterAndroidValues());

  NativeSection read(String project, {bool withFlutter = true}) =>
      readAndroidNative(
        nativeContext(project, android: withFlutter ? flutter : null),
      );

  NativeValue value(NativeSection section, List<String> path) =>
      NativeConfig({'android': section.node}).lookup(['android', ...path])!
          as NativeValue;

  Map<String, Object?> json(NativeValue value) => value.toJson();

  group('the template app', () {
    late String app;
    late NativeSection section;

    setUp(() {
      app = copyNativeTemplate();
      section = read(app);
    });

    String at(String file, String text) => '$file:${lineOf(app, file, text)}';
    const appFile = 'android/app/build.gradle.kts';

    test('build files, plugin versions, Gradle and its properties', () {
      expect(json(value(section, ['buildLanguage'])), {
        'status': 'found',
        'value': 'kts',
      });
      const settings = 'android/settings.gradle.kts';
      expect(json(value(section, ['settings', 'agp'])), {
        'status': 'found',
        'value': '9.1.0',
        'at': at(settings, '"com.android.application"'),
      });
      expect(value(section, ['settings', 'kgp']).value, '2.4.0');
      expect(
        value(section, ['settings', 'flutterPluginLoader']).value,
        '1.0.0',
      );
      expect(value(section, ['gradle', 'version']).value, '9.3.1');
      expect(value(section, ['gradle', 'distribution']).value, 'all');
      expect(
        value(section, ['gradleProperties', 'android.builtInKotlin']).toJson(),
        {
          'status': 'found',
          'value': 'false',
          'at': 'android/gradle.properties:6',
        },
      );
      expect(
        (section.node as NativeGroup).children['gradleProperties']!.toJson(),
        isNot(contains('org.gradle.jvmargs')),
      );
    });

    test('the app: ids, SDK levels resolved from Flutter, Java and Kotlin, '
        'signing', () {
      expect(value(section, ['app', 'plugins']).value, [
        'com.android.application',
        'dev.flutter.flutter-gradle-plugin',
      ]);
      expect(
        value(section, ['app', 'namespace']).value,
        'dev.sample.probe_app',
      );
      expect(
        value(section, ['app', 'applicationId']).at,
        at(appFile, 'applicationId ='),
      );
      expect(json(value(section, ['app', 'minSdk'])), {
        'status': 'found',
        'value': 24,
        'at': at(appFile, 'minSdk ='),
        'expression': 'flutter.minSdkVersion',
        'resolvedFrom': 'flutter',
      });
      expect(value(section, ['app', 'compileSdk']).value, 36);
      expect(value(section, ['app', 'targetSdk']).value, 36);
      expect(value(section, ['app', 'ndkVersion']).value, '28.2.13676358');
      expect(json(value(section, ['app', 'versionCode'])), {
        'status': 'found',
        'value': 1,
        'at': at(appFile, 'versionCode ='),
        'expression': 'flutter.versionCode',
        'resolvedFrom': 'pubspec.yaml:19',
      });
      expect(value(section, ['app', 'versionName']).value, '1.0.0');
      expect(
        value(section, ['app', 'javaSourceCompatibility']).value,
        'JavaVersion.VERSION_17',
      );
      expect(
        value(section, ['app', 'kotlinJvmTarget']).value,
        'org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17',
      );
      expect(json(value(section, ['app', 'releaseSigningConfig'])), {
        'status': 'found',
        'value': 'debug',
        'at': at(appFile, 'signingConfig ='),
        'expression': 'signingConfigs.getByName("debug")',
      });
      expect(
        value(section, ['app', 'signingConfigs']).status,
        NativeStatus.absent,
      );
      expect(
        (section.node as NativeGroup).children['app']!.toJson(),
        containsPair('flavors', <Object?>[]),
      );
    });

    test('the manifests', () {
      expect(value(section, ['manifests', 'main', 'label']).value, 'probe_app');
      expect(value(section, ['manifests', 'main', 'icon']).toJson(), {
        'status': 'found',
        'value': '@mipmap/ic_launcher',
        'at': 'android/app/src/main/AndroidManifest.xml:5',
      });
      final debug = NativeConfig({
        'android': section.node,
      }).lookup(['android', 'manifests', 'debug', 'permissions'])!;
      expect(debug.toJson(), [
        {
          'name': 'android.permission.INTERNET',
          'at': 'android/app/src/debug/AndroidManifest.xml:6',
        },
      ]);
    });

    test('every file read is an input, and the Flutter values too', () {
      expect(
        section.inputs.keys,
        containsAll([
          'file:android/settings.gradle.kts',
          'file:android/settings.gradle',
          'file:android/app/build.gradle.kts',
          'file:android/gradle/wrapper/gradle-wrapper.properties',
          'file:android/gradle.properties',
          'file:android/app/src/main/AndroidManifest.xml',
          'file:pubspec.yaml',
          'flutter-values',
        ]),
      );
      expect(section.inputs['file:android/settings.gradle'], isNull);
    });

    test("without Flutter's values, flutter.* is unknown, never guessed", () {
      final bare = read(app, withFlutter: false);
      expect(value(bare, ['app', 'minSdk']).status, NativeStatus.unknown);
      expect(
        value(bare, ['app', 'minSdk']).reason,
        contains('flutter.minSdkVersion'),
      );
      expect(value(bare, ['app', 'versionCode']).value, 1);
    });
  });

  group('projects that are not the template', () {
    late String app;

    setUp(() {
      app = p.join(tempDir().path, 'other app');
      writeProjectFiles(app, {
        'pubspec.yaml': 'name: other\nversion: 2.3.4+56\n',
        'android/app/src/main/AndroidManifest.xml':
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '  <application android:label="Other"/>\n'
            '</manifest>\n',
      });
    });

    test('no android folder: the whole section is absent', () {
      final empty = tempDir().path;
      expect(read(empty).node.toJson(), {
        'status': 'absent',
        'reason': 'no android/ folder',
      });
    });

    test('Groovy only: Gradle values say why, the manifest is still read', () {
      writeProjectFiles(app, {
        'android/settings.gradle': "include ':app'\n",
        'android/app/build.gradle': 'android { minSdkVersion 21 }\n',
      });
      final section = read(app);
      expect(value(section, ['buildLanguage']).value, 'groovy');
      expect(json(value(section, ['app'])), {
        'status': 'unknown',
        'reason': "Groovy build files aren't read yet",
        'at': 'android/app/build.gradle',
      });
      expect(
        value(section, ['settings', 'agp']).reason,
        "Groovy build files aren't read yet",
      );
      expect(value(section, ['manifests', 'main', 'label']).value, 'Other');
    });

    test('half converted: mixed, and both forms of one file', () {
      writeProjectFiles(app, {
        'android/settings.gradle.kts': 'include(":app")\n',
        'android/app/build.gradle': 'android {}\n',
      });
      expect(value(read(app), ['buildLanguage']).value, 'mixed');
      writeProjectFiles(app, {'android/app/build.gradle.kts': 'android {}\n'});
      expect(
        value(read(app), ['app']).reason,
        'both android/app/build.gradle and android/app/build.gradle.kts exist',
      );
    });

    test('values that are not plain are unknown with the reason', () {
      writeProjectFiles(app, {
        'android/app/build.gradle.kts': '''
android {
    namespace = "a"
    compileSdk = 35
    defaultConfig {
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = 35
        targetSdk = 36
        if (ci) {
            versionCode = 3
        }
        minSdkVersion(21)
        applicationId = appIdFromSomewhere
    }
    ndkVersion = flutter.someNewThing
}
afterEvaluate {
    android { compileOptions { sourceCompatibility = JavaVersion.VERSION_21 } }
}
''',
      });
      final section = read(app);
      expect(value(section, ['app', 'namespace']).value, 'a');
      expect(value(section, ['app', 'compileSdk']).toJson(), {
        'status': 'found',
        'value': 35,
        'at': 'android/app/build.gradle.kts:3',
      });
      expect(
        value(section, ['app', 'minSdk']).reason,
        'set with the old name `minSdkVersion` (line 11)',
      );
      expect(value(section, ['app', 'targetSdk']).toJson(), {
        'status': 'unknown',
        'reason': 'set more than once (lines 6, 7)',
        'at': 'android/app/build.gradle.kts:6',
      });
      expect(
        value(section, ['app', 'versionCode']).reason,
        startsWith('set conditionally'),
      );
      expect(
        value(section, ['app', 'applicationId']).reason,
        'computed in Gradle code: `appIdFromSomewhere`',
      );
      expect(
        value(section, ['app', 'ndkVersion']).reason,
        contains('flutter.someNewThing'),
      );
      expect(
        value(section, ['app', 'javaSourceCompatibility']).reason,
        "set inside `afterEvaluate { }`, which Appstein doesn't follow",
      );
      expect(
        value(section, ['app', 'versionName']).status,
        NativeStatus.absent,
      );
    });

    test('a computed value names the expression', () {
      writeProjectFiles(app, {
        'android/app/build.gradle.kts':
            'android { defaultConfig { minSdk = maxOf(flutter.minSdkVersion, 26) } }\n',
      });
      expect(
        value(read(app), ['app', 'minSdk']).reason,
        'computed in Gradle code: `maxOf(flutter.minSdkVersion, 26)`',
      );
    });

    test('flavors, signing configs by name, and no secrets', () {
      writeProjectFiles(app, {
        'android/gradle.properties':
            'MYAPP_UPLOAD_STORE_PASSWORD=hunter2\nkotlin.code.style=official\n',
        'android/app/build.gradle.kts': '''
android {
    signingConfigs {
        create("release") {
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = "hunter2"
        }
    }
    flavorDimensions += "env"
    productFlavors {
        create("prod") { dimension = "env" }
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            minSdk = 26
        }
    }
    buildTypes {
        release { signingConfig = signingConfigs.getByName("release") }
    }
}
''',
      });
      final section = read(app);
      expect(value(section, ['app', 'signingConfigs']).value, ['release']);
      expect(value(section, ['app', 'releaseSigningConfig']).value, 'release');
      final flavors = NativeConfig({
        'android': section.node,
      }).lookup(['android', 'app', 'flavors'])!;
      expect(flavors.toJson(), [
        {
          'name': 'dev',
          'at': 'android/app/build.gradle.kts:11',
          'applicationIdSuffix': {
            'status': 'found',
            'value': '.dev',
            'at': 'android/app/build.gradle.kts:13',
          },
          'dimension': {
            'status': 'found',
            'value': 'env',
            'at': 'android/app/build.gradle.kts:12',
          },
          'minSdk': {
            'status': 'found',
            'value': 26,
            'at': 'android/app/build.gradle.kts:14',
          },
        },
        {
          'name': 'prod',
          'at': 'android/app/build.gradle.kts:10',
          'dimension': {
            'status': 'found',
            'value': 'env',
            'at': 'android/app/build.gradle.kts:10',
          },
        },
      ]);
      expect(
        value(section, ['gradleProperties', 'kotlin.code.style']).value,
        'official',
      );
      final text = jsonEncode(section.node.toJson());
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('MYAPP_UPLOAD_STORE_PASSWORD')));
      expect(text, isNot(contains('keystore')));
    });

    test('a flavor with a computed name makes the flavors unknown', () {
      writeProjectFiles(app, {
        'android/app/build.gradle.kts':
            'android {\n  productFlavors {\n    create(name) { }\n  }\n}\n',
      });
      expect(
        value(read(app), ['app', 'flavors']).reason,
        'a flavor is created with a computed name',
      );
    });

    test("versionCode and versionName follow Flutter's rules", () {
      void version(String? line) => writeProjectFiles(app, {
        'pubspec.yaml': 'name: other\n${line ?? ''}',
        'android/app/build.gradle.kts':
            'android { defaultConfig {\n'
            '  versionCode = flutter.versionCode\n'
            '  versionName = flutter.versionName\n'
            '} }\n',
      });
      Object? code() => value(read(app), ['app', 'versionCode']).value;
      Object? name() => value(read(app), ['app', 'versionName']).value;

      version('version: 1.2.3+45\n');
      expect([code(), name()], [45, '1.2.3']);
      version('version: 1.2.3\n');
      expect([code(), name()], [1, '1.2.3']);
      expect(
        value(read(app), ['app', 'versionCode']).toJson(),
        containsPair('resolvedFrom', 'default'),
      );
      version('version: 1.0.0+0\n');
      expect(code(), 1);
      version(null);
      expect([code(), name()], [1, '1.0']);
      version('version: not.a.version\n');
      expect(
        value(read(app), ['app', 'versionName']).note,
        "pubspec.yaml's version `not.a.version` isn't valid",
      );
    });

    test(
      'AGP declared in settings and in a buildscript classpath is unknown',
      () {
        writeProjectFiles(app, {
          'android/settings.gradle.kts':
              'plugins {\n  id("com.android.application") version "8.7.0" apply false\n}\n',
          'android/build.gradle.kts':
              'buildscript {\n  dependencies {\n'
              '    classpath("com.android.tools.build:gradle:8.1.0")\n'
              '  }\n}\n',
        });
        expect(
          value(read(app), ['settings', 'agp']).reason,
          'declared more than once (android/settings.gradle.kts:2, '
          'android/build.gradle.kts:3)',
        );
      },
    );

    test(
      'damaged files: not UTF-8, broken XML, broken Kotlin, BOM and CRLF',
      () {
        File(p.join(app, 'android', 'gradle.properties'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([0xFF, 0xFE, 0x41]);
        writeProjectFiles(app, {
          'android/app/src/debug/AndroidManifest.xml':
              '<manifest>\n<oops>\n</manifest>\n',
          'android/settings.gradle.kts': 'plugins {\n  id("a"\n',
        });
        File(
          p.join(app, 'android', 'app', 'build.gradle.kts'),
        ).writeAsBytesSync([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode('android {\r\n    namespace = "crlf"\r\n}\r\n'),
        ]);
        final section = read(app);
        expect(value(section, ['gradleProperties']).toJson(), {
          'status': 'unknown',
          'reason': 'could not be read: not valid UTF-8',
          'at': 'android/gradle.properties',
        });
        expect(
          value(section, ['manifests', 'debug']).reason,
          startsWith('not valid XML'),
        );
        expect(
          value(section, ['settings', 'agp']).reason,
          startsWith('could not be read'),
        );
        expect(value(section, ['app', 'namespace']).toJson(), {
          'status': 'found',
          'value': 'crlf',
          'at': 'android/app/build.gradle.kts:2',
        });
        expect(value(section, ['manifests', 'main', 'label']).value, 'Other');
      },
    );
  });
}
