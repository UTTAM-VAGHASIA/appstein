import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/src/native/native_extractor.dart';
import 'package:appstein_engine/src/packs/android/android_native.dart';
import 'package:appstein_engine/src/packs/android/kts_reader.dart';
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
      // The debug manifest has no <application>: say so.
      expect(
        value(section, ['manifests', 'debug', 'icon']).reason,
        'no <application> element in android/app/src/debug/AndroidManifest.xml',
      );
      expect(
        value(section, ['manifests', 'main', 'label']).status,
        NativeStatus.found,
      );
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
        startsWith('a flavor is created with a computed name'),
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

    group('never guess (review round 1)', () {
      void gradle(String text) =>
          writeProjectFiles(app, {'android/app/build.gradle.kts': text});

      test('a damaged pubspec.yaml makes flutter.version* unknown', () {
        gradle(
          'android { defaultConfig {\n'
          '  versionCode = flutter.versionCode\n'
          '  versionName = flutter.versionName\n'
          '} }\n',
        );
        for (final bytes in [
          <int>[0xFF, 0xFE, 0x41],
          utf8.encode('name: [broken\n'),
          utf8.encode('- a\n- b\n'),
        ]) {
          File(p.join(app, 'pubspec.yaml')).writeAsBytesSync(bytes);
          final section = read(app);
          for (final key in ['versionCode', 'versionName']) {
            final v = value(section, ['app', key]);
            expect(v.status, NativeStatus.unknown, reason: '$bytes $key');
            expect(v.reason, startsWith('pubspec.yaml could not be read'));
            expect(v.at, 'pubspec.yaml');
          }
        }
      });

      test('plugins declared with alias(...) or a computed id are unknown', () {
        writeProjectFiles(app, {
          'android/settings.gradle.kts':
              'plugins {\n'
              '  alias(libs.plugins.android.application) apply false\n'
              '}\n',
          'android/build.gradle.kts':
              'plugins {\n  id(kgpId) version "2.0.0"\n}\n',
        });
        final section = read(app);
        for (final key in ['agp', 'kgp', 'flutterPluginLoader']) {
          final v = value(section, ['settings', key]);
          expect(v.status, NativeStatus.unknown, reason: key);
          expect(v.reason, contains("Appstein can't name or evaluate"));
        }
        // Found plainly elsewhere still wins.
        writeProjectFiles(app, {
          'android/build.gradle.kts':
              'plugins {\n  id("com.android.application") version "8.1.0"\n}\n',
        });
        expect(read(app).node, isA<NativeGroup>());
        expect(value(read(app), ['settings', 'agp']).value, '8.1.0');
      });

      test('a classpath that is not a string is unknown, not absent', () {
        writeProjectFiles(app, {
          'android/build.gradle.kts':
              'buildscript { dependencies { classpath(libs.agp) } }\n',
        });
        expect(
          value(read(app), ['settings', 'agp']).status,
          NativeStatus.unknown,
        );
      });

      test('a version in a call chain is never "declared without a version"', () {
        writeProjectFiles(app, {
          'android/settings.gradle.kts':
              'plugins {\n  id("com.android.application").version("8.1.0")\n}\n',
        });
        final agp = value(read(app), ['settings', 'agp']);
        expect(agp.status, NativeStatus.unknown);
        expect(agp.at, 'android/settings.gradle.kts:2');
      });

      test('flavors made with calls, and old names in flavors', () {
        gradle(
          'android {\n'
          '  productFlavors {\n'
          '    create("free")\n'
          '    register("paid")\n'
          '    create("dev") { minSdkVersion(26); targetSdkVersion(30) }\n'
          '  }\n'
          '}\n',
        );
        final flavors =
            NativeConfig({
                  'android': read(app).node,
                }).lookup(['android', 'app', 'flavors'])!.toJson()
                as List<Object?>;
        final byName = {
          for (final f in flavors.cast<Map<String, Object?>>())
            f['name']! as String: f,
        };
        expect(byName.keys, containsAll(['free', 'paid', 'dev']));
        expect(byName['free'], {
          'name': 'free',
          'at': 'android/app/build.gradle.kts:3',
        });
        final dev = byName['dev']!;
        expect(
          (dev['minSdk']! as Map)['reason'],
          'set with the old name `minSdkVersion` (line 5)',
        );
        expect((dev['targetSdk']! as Map)['status'], 'unknown');
      });

      test(
        'flavors and signing configs the reader can not name are unknown',
        () {
          for (final body in [
            'if (ci) { create("ci") {} }',
            'val staging by creating { }',
            'create("qa").apply { }',
            'if (ci) { create("ci") }',
          ]) {
            gradle('android { productFlavors { $body } }\n');
            final v = value(read(app), ['app', 'flavors']);
            expect(v.status, NativeStatus.unknown, reason: body);
            expect(
              v.reason,
              contains("in a way Appstein doesn't follow"),
              reason: body,
            );
          }
          gradle('android { productFlavors { create(name) } }\n');
          expect(
            value(read(app), ['app', 'flavors']).reason,
            'a flavor is created with a computed name',
          );
          gradle(
            'afterEvaluate { android { productFlavors { create("x") {} } } }\n',
          );
          expect(
            value(read(app), ['app', 'flavors']).status,
            NativeStatus.unknown,
          );
          gradle('android { signingConfigs { if (ci) { create("r") {} } } }\n');
          expect(
            value(read(app), ['app', 'signingConfigs']).status,
            NativeStatus.unknown,
          );
        },
      );

      test('a value set where the reader can not place it is unknown', () {
        gradle(
          'android { }\n'
          'tasks.withType<KotlinCompile>().configureEach {\n'
          '  kotlinOptions { jvmTarget = "17" }\n'
          '}\n',
        );
        final jvm = value(read(app), ['app', 'kotlinJvmTarget']);
        expect(jvm.status, NativeStatus.unknown);
        expect(jvm.reason, startsWith("set where Appstein doesn't follow"));
        expect(jvm.at, 'android/app/build.gradle.kts:3');
        gradle(
          'android { defaultConfig { } }\n'
          'project.afterEvaluate { android.defaultConfig.apply { minSdk = 30 } }\n',
        );
        expect(
          value(read(app), ['app', 'minSdk']).status,
          NativeStatus.unknown,
        );
        // A flavor's own minSdk is not defaultConfig's.
        gradle('android { productFlavors { create("a") { minSdk = 26 } } }\n');
        expect(value(read(app), ['app', 'minSdk']).status, NativeStatus.absent);
      });

      test('release signing set through getByName("release").apply { }', () {
        for (final body in [
          'android { buildTypes { getByName("release").apply {\n'
              '  signingConfig = signingConfigs.getByName("release")\n'
              '} } }\n',
          'android { buildTypes.getByName("release").apply {\n'
              '  signingConfig = signingConfigs.getByName("release")\n'
              '} }\n',
        ]) {
          gradle(body);
          final v = value(read(app), ['app', 'releaseSigningConfig']);
          expect(v.status, NativeStatus.unknown, reason: body);
        }
      });

      test('kotlin jvmTarget.set(...) is read; elsewhere it is unknown', () {
        gradle(
          'kotlin {\n  compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }\n}\n',
        );
        expect(json(value(read(app), ['app', 'kotlinJvmTarget'])), {
          'status': 'found',
          'value': 'JvmTarget.JVM_17',
          'at': 'android/app/build.gradle.kts:2',
        });
        gradle(
          'tasks.withType<KotlinCompile>().configureEach {\n'
          '  compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }\n'
          '}\n',
        );
        expect(
          value(read(app), ['app', 'kotlinJvmTarget']).status,
          NativeStatus.unknown,
        );
      });

      test('release uses the signing config set in defaultConfig', () {
        gradle(
          'android { defaultConfig {\n'
          '  signingConfig = signingConfigs.getByName("shared")\n'
          '} }\n',
        );
        final v = value(read(app), ['app', 'releaseSigningConfig']);
        expect(v.status, NativeStatus.found);
        expect(v.value, 'shared');
        expect(v.at, 'android/app/build.gradle.kts:2');
        expect(v.note, contains('defaultConfig'));
        gradle(
          'android { defaultConfig {\n'
          '  signingConfig = mySigning\n'
          '} }\n',
        );
        expect(
          value(read(app), ['app', 'releaseSigningConfig']).status,
          NativeStatus.unknown,
        );
      });

      test('a flavor signing config beats the defaultConfig one', () {
        gradle(
          'android {\n'
          '  defaultConfig { signingConfig = signingConfigs.getByName("shared") }\n'
          '  productFlavors {\n'
          '    create("dev") { signingConfig = signingConfigs.getByName("dev") }\n'
          '  }\n'
          '}\n',
        );
        final v = value(read(app), ['app', 'releaseSigningConfig']);
        expect(v.status, NativeStatus.unknown);
        expect(v.reason, contains('flavors set their own signing configs'));
        gradle(
          'android {\n'
          '  defaultConfig { signingConfig = signingConfigs.getByName("shared") }\n'
          '  productFlavors { create(name) }\n'
          '}\n',
        );
        expect(
          value(read(app), ['app', 'releaseSigningConfig']).status,
          NativeStatus.unknown,
        );
      });

      test('a conditional value in one block does not leak to its siblings', () {
        gradle(
          'android {\n'
          '  defaultConfig { if (ci) { versionCode = 3 } }\n'
          '  productFlavors { create("a") { dimension = "x" } }\n'
          '}\n',
        );
        final section = read(app);
        final flavors = NativeConfig({
          'android': section.node,
        }).lookup(['android', 'app', 'flavors'])!.toJson();
        expect(flavors, [
          {
            'name': 'a',
            'at': 'android/app/build.gradle.kts:3',
            'dimension': {
              'status': 'found',
              'value': 'x',
              'at': 'android/app/build.gradle.kts:3',
            },
          },
        ]);
        gradle(
          'android { productFlavors { create("a") { if (ci) { minSdk = 3 } } } }\n',
        );
        expect(value(read(app), ['app', 'minSdk']).status, NativeStatus.absent);
      });

      test('Java toolchain blocks set the Kotlin target implicitly', () {
        for (final body in [
          'kotlin { jvmToolchain { languageVersion.set(JavaLanguageVersion.of(17)) } }\n',
          'java { toolchain { languageVersion.set(JavaLanguageVersion.of(17)) } }\n',
        ]) {
          gradle(body);
          final v = value(read(app), ['app', 'kotlinJvmTarget']);
          expect(v.status, NativeStatus.unknown, reason: body);
          expect(v.reason, 'set by a Java toolchain (line 1)', reason: body);
        }
      });

      test('kotlin jvmToolchain(...) sets the target implicitly', () {
        gradle('kotlin { jvmToolchain(17) }\n');
        final v = value(read(app), ['app', 'kotlinJvmTarget']);
        expect(v.status, NativeStatus.unknown);
        expect(v.reason, 'set by jvmToolchain(17) (line 1)');
      });

      test(
        "AGP's block form of compileSdk, minSdk and targetSdk is unknown",
        () {
          gradle(
            'android {\n'
            '  compileSdk { version = release(36) }\n'
            '  defaultConfig {\n'
            '    minSdk { version = release(24) }\n'
            '    targetSdk { version = release(36) }\n'
            '  }\n'
            '}\n',
          );
          final section = read(app);
          final lines = {'compileSdk': 2, 'minSdk': 4, 'targetSdk': 5};
          for (final MapEntry(key: key, value: line) in lines.entries) {
            final v = value(section, ['app', key]);
            expect(v.status, NativeStatus.unknown, reason: key);
            expect(v.at, 'android/app/build.gradle.kts:$line', reason: key);
          }
          // A block of another key is not this key's.
          gradle('android { defaultConfig { versionCode { } } }\n');
          expect(
            value(read(app), ['app', 'minSdk']).status,
            NativeStatus.absent,
          );
        },
      );

      test(
        "a flavor's block-form minSdk is that flavor's, not defaultConfig's",
        () {
          gradle(
            'android { productFlavors { create("a") {\n'
            '  minSdk { version = release(26) }\n'
            '} } }\n',
          );
          final section = read(app);
          expect(value(section, ['app', 'minSdk']).status, NativeStatus.absent);
          final flavors = NativeConfig({
            'android': section.node,
          }).lookup(['android', 'app', 'flavors'])!.toJson();
          expect(flavors, [
            {
              'name': 'a',
              'at': 'android/app/build.gradle.kts:1',
              'minSdk': {
                'status': 'unknown',
                'reason': "set where Appstein doesn't follow (line 2)",
                'at': 'android/app/build.gradle.kts:2',
              },
            },
          ]);
        },
      );

      test(
        'it and this are the receiver: a key set through them is unknown',
        () {
          for (final body in [
            'android { defaultConfig.let { it.minSdk = 21 } }\n',
            'android { defaultConfig.apply { this.minSdk = 21 } }\n',
            'android { defaultConfig { this.minSdk = 21 } }\n',
          ]) {
            gradle(body);
            expect(
              value(read(app), ['app', 'minSdk']).status,
              NativeStatus.unknown,
              reason: body,
            );
          }
        },
      );

      test('an old setter call sets its key', () {
        gradle('android { defaultConfig { setMinSdkVersion(21) } }\n');
        final v = value(read(app), ['app', 'minSdk']);
        expect(v.status, NativeStatus.unknown);
        expect(v.reason, 'set with the old name `minSdkVersion` (line 1)');
        gradle('android { setNamespace("x") }\n');
        final namespace = value(read(app), ['app', 'namespace']);
        expect(namespace.status, NativeStatus.unknown);
        expect(
          namespace.reason,
          startsWith("set where Appstein doesn't follow"),
        );
      });

      test('containers created inside nested scope functions are unknown', () {
        gradle(
          'android.apply { productFlavors.apply { create("dev") { } } }\n',
        );
        final section = read(app);
        final flavors = NativeConfig({
          'android': section.node,
        }).lookup(['android', 'app', 'flavors'])!;
        expect((flavors as NativeValue).status, NativeStatus.unknown);
        gradle(
          'android { }\n'
          'with(android) { signingConfigs.apply { create("upload") { } } }\n',
        );
        expect(
          value(read(app), ['app', 'signingConfigs']).status,
          NativeStatus.unknown,
        );
      });

      test('a key set twice on one line is set more than once', () {
        gradle('android { defaultConfig { minSdk = 21; minSdk = 23 } }\n');
        final v = value(read(app), ['app', 'minSdk']);
        expect(v.status, NativeStatus.unknown);
        expect(v.reason, startsWith('set more than once'));
        gradle(
          'android { productFlavors { create("a") { minSdk = 21; minSdk = 23 } } }\n',
        );
        final flavors = NativeConfig({
          'android': read(app).node,
        }).lookup(['android', 'app', 'flavors'])!.toJson();
        final minSdk = (flavors as List).single['minSdk'] as Map;
        expect(minSdk['status'], 'unknown');
        expect(minSdk['reason'], startsWith('set more than once'));
        gradle(
          'android { }\n'
          'kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_11; '
          'jvmTarget = JvmTarget.JVM_17 } }\n',
        );
        final jvm = value(read(app), ['app', 'kotlinJvmTarget']);
        expect(jvm.status, NativeStatus.unknown);
        expect(jvm.reason, startsWith('set more than once'));
      });

      test('deeply nested scope functions stay linear, lines listed once', () {
        const depth = 20;
        final text = StringBuffer('android {\n  defaultConfig {\n');
        for (var i = 0; i < depth; i++) {
          text.writeln('a$i.apply {');
        }
        text.writeln('minSdk = 1');
        text.writeln('minSdk = 2');
        text.writeln('}' * depth);
        text.writeln('  }\n}');
        final script = readKts(text.toString());
        // 2 assignments, each read at most 2^3 times, not 2^20.
        expect(script.assignments.length, lessThanOrEqualTo(16));
        gradle(text.toString());
        final v = value(read(app), ['app', 'minSdk']);
        expect(v.status, NativeStatus.unknown);
        expect(
          v.reason,
          'set more than once (lines ${depth + 3}, ${depth + 4})',
        );
      });
    });
  });
}
