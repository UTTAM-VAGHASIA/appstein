import 'package:appstein_engine/src/packs/android/kts_reader.dart';
import 'package:test/test.dart';

void main() {
  KtsAssignment only(KtsScript script, List<String> path) {
    final found = script.assignmentsTo(path);
    expect(found, hasLength(1), reason: path.join('.'));
    return found.single;
  }

  test("the template's app/build.gradle.kts", () {
    final script = readKts('''
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.sample.probe_app"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = flutter.minSdkVersion
        versionCode = flutter.versionCode
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
''');
    final namespace = only(script, ['android', 'namespace']);
    expect((namespace.value as KtsString).value, 'dev.sample.probe_app');
    expect(namespace.line, 8);
    expect(namespace.conditional, isFalse);
    expect(
      only(script, ['android', 'compileSdk']).value,
      isA<KtsName>().having((v) => v.text, 'text', 'flutter.compileSdkVersion'),
    );
    expect(only(script, ['android', 'defaultConfig', 'minSdk']).line, 16);
    expect(
      only(script, [
        'android',
        'compileOptions',
        'sourceCompatibility',
      ]).value.text,
      'JavaVersion.VERSION_17',
    );
    expect(
      only(script, ['kotlin', 'compilerOptions', 'jvmTarget']).value.text,
      'org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17',
    );
    final signing =
        only(script, [
              'android',
              'buildTypes',
              'release',
              'signingConfig',
            ]).value
            as KtsCallValue;
    expect(signing.name, 'signingConfigs.getByName');
    expect(signing.argument, 'debug');
    expect(signing.text, 'signingConfigs.getByName("debug")');
    final plugins = script.callsTo(['plugins'], 'id');
    expect(
      [for (final call in plugins) (call.argument! as KtsString).value],
      ['com.android.application', 'dev.flutter.flutter-gradle-plugin'],
    );
    expect(plugins.first.line, 2);
  });

  test("the template's settings.gradle.kts: plugins with versions, and a "
      'declaration whose block is skipped', () {
    final script = readKts(r'''
pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
''');
    final ids = script.callsTo(['plugins'], 'id');
    expect(ids, hasLength(3));
    final agp = ids[1];
    expect((agp.argument! as KtsString).value, 'com.android.application');
    expect((agp.infix['version']! as KtsString).value, '9.1.0');
    expect((agp.infix['apply']! as KtsBool).value, isFalse);
    expect(agp.line, 16);
    final include = script.callsTo(['pluginManagement'], 'includeBuild').single;
    expect(include.argument, isNull, reason: 'a template string');
    expect(script.callsTo([], 'include').single.argument!.text, '":app"');
  });

  test('a dotted assignment has the same path as the nested one', () {
    final script = readKts('''
android.defaultConfig.minSdk = 21
android {
    defaultConfig.targetSdk = 35
}
''');
    expect(only(script, ['android', 'defaultConfig', 'minSdk']).line, 1);
    expect(only(script, ['android', 'defaultConfig', 'targetSdk']).line, 3);
    expect(
      ktsPathIs(only(script, ['android', 'defaultConfig', 'targetSdk']).path, [
        'android',
        'defaultConfig',
        'targetSdk',
      ]),
      isTrue,
    );
  });

  test('values inside if, a braceless if, when, a lambda or an unknown '
      'block are still seen, and marked', () {
    final script = readKts('''
android {
    defaultConfig {
        if (System.getenv("CI") != null) {
            minSdk = 26
        } else {
            minSdk = 24
        }
        if (big) targetSdk = 35
        versionCode = when (flavor) {
            "a" -> 1
            else -> 2
        }
    }
}
afterEvaluate {
    android {
        compileSdk = 36
    }
}
''');
    final minSdk = script.assignmentsTo(['android', 'defaultConfig', 'minSdk']);
    expect(minSdk, hasLength(2));
    expect(minSdk.every((a) => a.conditional), isTrue);
    expect(
      only(script, ['android', 'defaultConfig', 'targetSdk']).conditional,
      isTrue,
    );
    expect(
      only(script, ['android', 'defaultConfig', 'versionCode']).value,
      isA<KtsComputed>(),
    );
    final compileSdk = only(script, ['android', 'compileSdk']);
    expect(compileSdk.conditional, isFalse);
    expect(compileSdk.path, ['afterEvaluate', 'android', 'compileSdk']);
    expect(ktsPathIs(compileSdk.path, ['android', 'compileSdk']), isFalse);
  });

  test('values that are not plain are KtsComputed with their text', () {
    final script = readKts(r'''
android {
    defaultConfig {
        minSdk = maxOf(flutter.minSdkVersion, 26)
        applicationId = "dev.sample.$suffix"
        versionName = flutterVersionName
            .trim()
        manifestPlaceholders += mapOf("a" to "b")
        targetSdk = -1
    }
}
''');
    String text(String key) =>
        only(script, ['android', 'defaultConfig', key]).value.text;
    expect(
      only(script, ['android', 'defaultConfig', 'minSdk']).value,
      isA<KtsComputed>(),
    );
    expect(text('minSdk'), 'maxOf(flutter.minSdkVersion, 26)');
    expect(
      only(script, ['android', 'defaultConfig', 'applicationId']).value,
      isA<KtsComputed>(),
    );
    expect(text('versionName'), 'flutterVersionName.trim()');
    expect(
      only(script, ['android', 'defaultConfig', 'manifestPlaceholders']).value,
      isA<KtsComputed>(),
    );
    expect(text('targetSdk'), '- 1');
  });

  test('comments and strings never open or close a block', () {
    final script = readKts('''
android {
    // minSdk = 1 }
    /* outer /* inner } */ minSdk = 2 */
    namespace = "a}b{"
    val notes = """
        minSdk = 3 }
    """
    defaultConfig { minSdk = 4 }
}
''');
    expect(only(script, ['android', 'namespace']).value, isA<KtsString>());
    expect(
      (only(script, ['android', 'namespace']).value as KtsString).value,
      'a}b{',
    );
    final minSdk = only(script, ['android', 'defaultConfig', 'minSdk']);
    expect((minSdk.value as KtsInt).value, 4);
    expect(minSdk.line, 8);
  });

  test('named containers, type arguments and old call forms', () {
    final script = readKts('''
android {
    productFlavors {
        create("dev") { applicationIdSuffix = ".dev" }
        register("prod") {}
        create(flavorName) { applicationIdSuffix = ".x" }
    }
    buildTypes {
        getByName("release") { isMinifyEnabled = true }
    }
    defaultConfig {
        minSdkVersion(21)
    }
}
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
''');
    expect(
      [
        for (final block in script.blocksIn(['android', 'productFlavors']))
          block.path.last,
      ],
      ['dev', 'prod', ktsOpaque],
    );
    expect(
      only(script, [
        'android',
        'productFlavors',
        'dev',
        'applicationIdSuffix',
      ]).line,
      3,
    );
    expect(
      only(script, [
        'android',
        'buildTypes',
        'release',
        'isMinifyEnabled',
      ]).conditional,
      isFalse,
    );
    final old = script.callsTo(['android', 'defaultConfig'], 'minSdkVersion');
    expect((old.single.argument! as KtsInt).value, 21);
    expect(script.blocksIn(['tasks']).single.path, ['tasks', 'clean']);
  });

  test('a root buildscript classpath', () {
    final script = readKts('''
buildscript {
    dependencies {
        classpath("com.android.tools.build:gradle:8.1.0")
    }
}
''');
    final call = script.callsTo(['buildscript', 'dependencies'], 'classpath');
    expect(
      (call.single.argument! as KtsString).value,
      'com.android.tools.build:gradle:8.1.0',
    );
  });

  test('CRLF line ends keep the line numbers right', () {
    final script = readKts('android {\r\n    namespace = "a"\r\n}\r\n');
    expect(only(script, ['android', 'namespace']).line, 2);
  });

  test('backticked names and character literals are read', () {
    final script = readKts('''
plugins { `kotlin-dsl` }
android {
    val c = '}'
    namespace = "x"
}
''');
    expect(only(script, ['android', 'namespace']).line, 4);
  });

  test('I1: a wildcard import or a generic type does not swallow the next '
      'block', () {
    for (final head in [
      'import java.util.*\n',
      'package a.b\nimport java.util.*\n',
      'lateinit var names: List<String>\n',
    ]) {
      final script = readKts('$head\nandroid { namespace = "x" }\n');
      final found = only(script, ['android', 'namespace']);
      expect(found.conditional, isFalse, reason: head);
      expect(found.path, ['android', 'namespace'], reason: head);
    }
  });

  test('I2: scope functions, configure and call chains are marked, not '
      'missed', () {
    final script = readKts('''
android {
    defaultConfig.apply { targetSdk = 35 }
    with(defaultConfig) { minSdk = 21 }
    configure<ApplicationExtension> { defaultConfig { versionCode = 3 } }
    buildTypes.getByName("release").isMinifyEnabled = true
}
''');
    final target = only(script, ['android', 'defaultConfig', 'targetSdk']);
    expect(target.conditional, isTrue);
    expect(
      only(script, ['android', 'defaultConfig', 'minSdk']).conditional,
      isTrue,
    );
    expect(
      only(script, ['android', 'defaultConfig', 'versionCode']).conditional,
      isTrue,
    );
    final minify = only(script, [
      'android',
      'buildTypes',
      'release',
      'isMinifyEnabled',
    ]);
    expect(minify.conditional, isTrue);
    expect(minify.value, isA<KtsBool>());
  });

  test('round 2: let/also on a plain value never hide the key behind its '
      'name; apply on a DSL receiver keeps its path', () {
    final script = readKts('''
android {
    defaultConfig {
        envMin?.let { minSdk = it }
        envCode.also { versionCode = it }
        flag.run { targetSdk = 1 }
    }
    defaultConfig.apply { applicationId = "a" }
}
''');
    for (final key in ['minSdk', 'versionCode', 'targetSdk']) {
      final found = script.assignmentsTo(['android', 'defaultConfig', key]);
      expect(found, isNotEmpty, reason: key);
      expect(found.every((a) => a.conditional), isTrue, reason: key);
      expect(
        found.any(
          (a) => a.path.contains('envMin') || a.path.contains('envCode'),
        ),
        isFalse,
        reason: key,
      );
    }
    final id = only(script, ['android', 'defaultConfig', 'applicationId']);
    expect(id.path, ['android', 'defaultConfig', '?', 'applicationId']);
  });

  test(
    'round 2: collection callbacks are a ? entry, not an entry named all',
    () {
      for (final inner in [
        'all { applicationIdSuffix = ".x" }',
        'forEach { }',
        'configureEach { }',
        'whenObjectAdded { }',
        'matching { it.name == "a" }.all { }',
        'withType<Flavor> { }',
      ]) {
        final script = readKts('''
android {
    productFlavors {
        create("dev") { }
        $inner
    }
}
''');
        final names = [
          for (final block in script.blocksIn(['android', 'productFlavors']))
            block.path.last,
        ];
        expect(names, contains(ktsOpaque), reason: inner);
        expect(names, isNot(contains('all')), reason: inner);
        expect(names, isNot(contains('forEach')), reason: inner);
        expect(names, isNot(contains('withType')), reason: inner);
      }
    },
  );

  test('round 2: a call statement after a generic type is not swallowed', () {
    final script = readKts(
      'lateinit var names: List<String>\ninclude(":app")\n',
    );
    expect(script.callsTo([], 'include'), hasLength(1));
  });

  test('I3: entries declared in an if, a lambda, by creating or '
      'afterEvaluate leave a ? block', () {
    for (final inner in [
      'if (ci) { create("ci") {} }',
      'val staging by creating { applicationIdSuffix = ".s" }',
      'create("qa").apply { applicationIdSuffix = ".qa" }',
    ]) {
      final script = readKts('''
android {
    productFlavors {
        $inner
    }
}
''');
      expect(
        script
            .blocksIn(['android', 'productFlavors'])
            .any((block) => block.path.last == ktsOpaque),
        isTrue,
        reason: inner,
      );
    }
    final wrapped = readKts('''
afterEvaluate {
    android {
        productFlavors {
            create("late") {}
        }
    }
}
''');
    expect(
      wrapped
          .blocksIn(['android', 'productFlavors'])
          .any((block) => block.path.last == ktsOpaque),
      isTrue,
    );
  });

  test('I4: an infix value followed by an operator is computed', () {
    final script = readKts('''
plugins {
    id("com.android.application") version "8." + "1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}
''');
    final ids = script.callsTo(['plugins'], 'id');
    expect(ids[0].infix['version'], isA<KtsComputed>());
    expect(ids[0].infix['version']!.text, contains('"1.0"'));
    expect((ids[1].infix['version']! as KtsString).value, '2.4.0');
    expect((ids[1].infix['apply']! as KtsBool).value, isFalse);
  });

  test('broken scripts are a KtsFormatException with the line', () {
    for (final (text, line) in [
      ('android {\n    namespace = "a\n}\n', 2),
      ('android {\n    namespace = "a"\n', 1),
      ('android {\n}\n}\n', 3),
      ('/* never closed\n', 1),
      ('android(\n', 1),
    ]) {
      expect(
        () => readKts(text),
        throwsA(isA<KtsFormatException>().having((e) => e.line, 'line', line)),
        reason: text,
      );
    }
  });
}
