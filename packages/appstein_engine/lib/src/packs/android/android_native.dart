import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../knowledge/canonical_json.dart';
import '../../native/native_extractor.dart';
import '../../native/native_files.dart';
import 'kts_reader.dart';
import 'manifest_reader.dart';
import 'properties_reader.dart';

/// The keys of `gradle.properties` that `native.json` always lists. Keys
/// that start with `kotlin.` are listed too when set. Nothing else is read:
/// the file may hold signing passwords (spec §6.5).
const androidGradleProperties = [
  'android.builtInKotlin',
  'android.newDsl',
  'android.useAndroidX',
];

/// Calls that create or name an entry of a Gradle container.
const _containerCalls = {
  'create',
  'register',
  'getByName',
  'named',
  'maybeCreate',
};

/// Builds the `android` section of `native.json` (spec §6.5) from the
/// project's `android/` files and `pubspec.yaml`. It never throws for the
/// project's own problems.
NativeSection readAndroidNative(NativeContext context) {
  final root = context.projectRoot;
  if (!Directory(p.join(root, 'android')).existsSync()) {
    return const NativeSection(NativeValue.absent('no android/ folder'), {});
  }
  final inputs = <String, List<int>?>{};
  NativeFile read(String path) {
    final file = readNativeFile(root, path);
    inputs[file.input.key] = file.input.value;
    return file;
  }

  final settings = _GradleFile(read, 'android/settings.gradle');
  final rootBuild = _GradleFile(read, 'android/build.gradle');
  final app = _GradleFile(read, 'android/app/build.gradle');
  final flutter = _FlutterValues(context, read('pubspec.yaml'));
  inputs['flutter-values'] = utf8.encode(switch (context.android) {
    final android? => canonicalJson({
      ...android.value.template.toJson(),
      'source': android.source.name,
    }),
    null => 'none',
  });
  return NativeSection(
    NativeGroup({
      'buildLanguage': _buildLanguage([settings, rootBuild, app]),
      'settings': NativeGroup({
        'agp': _pluginVersion(
          settings,
          rootBuild,
          id: 'com.android.application',
          classpath: 'com.android.tools.build:gradle',
        ),
        'kgp': _pluginVersion(
          settings,
          rootBuild,
          id: 'org.jetbrains.kotlin.android',
          classpath: 'org.jetbrains.kotlin:kotlin-gradle-plugin',
        ),
        'flutterPluginLoader': _pluginVersion(
          settings,
          rootBuild,
          id: 'dev.flutter.flutter-plugin-loader',
        ),
      }),
      'gradle': _wrapper(
        read('android/gradle/wrapper/gradle-wrapper.properties'),
      ),
      'gradleProperties': _gradleProperties(read('android/gradle.properties')),
      'app': _app(app, flutter),
      'manifests': NativeGroup({
        for (final set in const ['main', 'debug', 'profile'])
          set: _manifest(read('android/app/src/$set/AndroidManifest.xml')),
      }),
    }),
    inputs,
  );
}

/// One Gradle build file, which may be written in Kotlin (`.kts`) or
/// Groovy.
final class _GradleFile {
  const _GradleFile._(this.kts, this.groovy, {this.script, this.problem});

  factory _GradleFile(NativeFile Function(String path) read, String base) {
    final kts = read('$base.kts');
    final groovy = read(base);
    NativeValue? problem;
    KtsScript? script;
    if (kts.exists && groovy.exists) {
      problem = NativeValue.unknown(
        'both ${groovy.path} and ${kts.path} exist',
        at: kts.path,
      );
    } else if (groovy.exists) {
      problem = NativeValue.unknown(
        "Groovy build files aren't read yet",
        at: groovy.path,
      );
    } else if (!kts.exists) {
      problem = NativeValue.absent('no ${kts.path}');
    } else if (kts.text case final text?) {
      try {
        script = readKts(text);
      } on KtsFormatException catch (error) {
        problem = NativeValue.unknown(
          'could not be read: ${error.message}',
          at: kts.at(error.line),
        );
      }
    } else {
      problem = NativeValue.unknown(
        'could not be read: ${kts.error}',
        at: kts.path,
      );
    }
    return _GradleFile._(kts, groovy, script: script, problem: problem);
  }

  final NativeFile kts;
  final NativeFile groovy;

  /// The script, when it could be read.
  final KtsScript? script;

  /// Why its values can't be read, or null when [script] holds them.
  final NativeValue? problem;

  /// `kts`, `groovy` or `both`, or null when neither exists.
  String? get language => kts.exists && groovy.exists
      ? 'both'
      : kts.exists
      ? 'kts'
      : groovy.exists
      ? 'groovy'
      : null;
}

typedef _Convert = NativeValue Function(KtsValue written, String at);

NativeValue _computed(KtsValue written, String at) =>
    NativeValue.unknown('computed in Gradle code: `${written.text}`', at: at);

/// The setting at [path] of [file], converted with [convert], or why it
/// can't be read. [oldNames] are the old forms of its key, such as
/// `minSdkVersion` for `minSdk`.
NativeValue _setting(
  _GradleFile file,
  List<String> path,
  _Convert convert, {
  List<String> oldNames = const [],
  String? absent,
}) {
  if (file.problem case final problem?) return problem;
  final script = file.script!;
  final parent = path.sublist(0, path.length - 1);
  for (final old in oldNames) {
    final lines = [
      for (final assignment in script.assignmentsTo([...parent, old]))
        assignment.line,
      for (final call in script.callsTo(parent, old)) call.line,
    ]..sort();
    if (lines.isNotEmpty) {
      return NativeValue.unknown(
        'set with the old name `$old` (line ${lines.join(', ')})',
        at: file.kts.at(lines.first),
      );
    }
  }
  final found = script.assignmentsTo(path);
  if (found.isEmpty) {
    return NativeValue.absent(
      absent ?? '`${path.last}` is not set in ${file.kts.path}',
    );
  }
  if (found.length > 1) {
    return NativeValue.unknown(
      'set more than once (lines '
      '${[for (final assignment in found) assignment.line].join(', ')})',
      at: file.kts.at(found.first.line),
    );
  }
  final assignment = found.single;
  final at = file.kts.at(assignment.line);
  if (assignment.conditional) {
    return NativeValue.unknown(
      'set conditionally (inside an `if`, `when`, loop or lambda)',
      at: at,
    );
  }
  if (!ktsPathIs(assignment.path, path)) {
    return NativeValue.unknown(
      "set inside `${assignment.path.first} { }`, which Appstein doesn't "
      'follow',
      at: at,
    );
  }
  return convert(assignment.value, at);
}

NativeValue _buildLanguage(List<_GradleFile> files) {
  final languages = {for (final file in files) ?file.language};
  if (languages.isEmpty) {
    return const NativeValue.absent('no Gradle build files in android/');
  }
  if (languages.length == 1 && languages.single != 'both') {
    return NativeValue.found(languages.single);
  }
  return const NativeValue.found('mixed');
}

/// The version of the plugin [id] (or the buildscript [classpath]
/// artifact) declared in `settings.gradle.kts` or `build.gradle.kts`.
NativeValue _pluginVersion(
  _GradleFile settings,
  _GradleFile rootBuild, {
  required String id,
  String? classpath,
}) {
  for (final file in [settings, rootBuild]) {
    if (file.problem case final problem?
        when problem.status != NativeStatus.absent) {
      return problem;
    }
  }
  final found = <({KtsValue? version, String at, bool conditional})>[];
  for (final file in [settings, rootBuild]) {
    final script = file.script;
    if (script == null) continue;
    for (final call in [
      ...script.callsTo(['plugins'], 'id'),
      ...script.callsTo(['plugins'], 'kotlin'),
    ]) {
      final called = switch ((call.name, call.argument)) {
        ('id', KtsString(:final value)) => value,
        ('kotlin', KtsString(:final value)) => 'org.jetbrains.kotlin.$value',
        _ => null,
      };
      if (called != id) continue;
      found.add((
        version: call.infix['version'],
        at: file.kts.at(call.line),
        conditional: call.conditional || !ktsPathIs(call.path, ['plugins']),
      ));
    }
    if (classpath == null) continue;
    final prefix = '$classpath:';
    for (final call in script.callsTo([
      'buildscript',
      'dependencies',
    ], 'classpath')) {
      if (!call.arguments.contains(prefix)) continue;
      final argument = call.argument;
      found.add((
        version: argument is KtsString && argument.value.startsWith(prefix)
            ? KtsString(argument.value.substring(prefix.length), argument.text)
            : KtsComputed(call.arguments),
        at: file.kts.at(call.line),
        conditional:
            call.conditional ||
            !ktsPathIs(call.path, ['buildscript', 'dependencies']),
      ));
    }
  }
  if (found.isEmpty) {
    return const NativeValue.absent(
      'not declared in android/settings.gradle.kts or '
      'android/build.gradle.kts',
    );
  }
  if (found.length > 1) {
    return NativeValue.unknown(
      'declared more than once (${[for (final f in found) f.at].join(', ')})',
      at: found.first.at,
    );
  }
  final only = found.single;
  if (only.conditional) {
    return NativeValue.unknown('declared conditionally', at: only.at);
  }
  return switch (only.version) {
    KtsString(:final value) => NativeValue.found(value, at: only.at),
    null => NativeValue.absent('declared without a version', at: only.at),
    final other => _computed(other, only.at),
  };
}

NativeNode _wrapper(NativeFile file) {
  if (!file.exists) return NativeValue.absent('no ${file.path}');
  final text = file.text;
  if (text == null) {
    return NativeValue.unknown(
      'could not be read: ${file.error}',
      at: file.path,
    );
  }
  final url = readProperties(text)['distributionUrl'];
  if (url == null) {
    final absent = NativeValue.absent(
      'no distributionUrl in ${file.path}',
      at: file.path,
    );
    return NativeGroup({'version': absent, 'distribution': absent});
  }
  final at = file.at(url.line);
  final match = RegExp(r'gradle-([^/]+)-(bin|all)\.zip$').firstMatch(url.value);
  if (match == null) {
    // The URL itself isn't repeated: it may be a local path.
    final unknown = NativeValue.unknown(
      "distributionUrl doesn't name a Gradle distribution "
      '(gradle-<version>-<bin|all>.zip)',
      at: at,
    );
    return NativeGroup({'version': unknown, 'distribution': unknown});
  }
  return NativeGroup({
    'version': NativeValue.found(match[1]!, at: at),
    'distribution': NativeValue.found(match[2]!, at: at),
  });
}

NativeNode _gradleProperties(NativeFile file) {
  if (!file.exists) return NativeValue.absent('no ${file.path}');
  final text = file.text;
  if (text == null) {
    return NativeValue.unknown(
      'could not be read: ${file.error}',
      at: file.path,
    );
  }
  final entries = readProperties(text);
  final keys = {
    ...androidGradleProperties,
    ...entries.keys.where((key) => key.startsWith('kotlin.')),
  };
  return NativeGroup({
    for (final key in keys)
      key: switch (entries[key]) {
        final entry? => NativeValue.found(entry.value, at: file.at(entry.line)),
        null => NativeValue.absent('not set in ${file.path}'),
      },
  });
}

NativeNode _app(_GradleFile app, _FlutterValues flutter) {
  if (app.problem case final problem?) return problem;
  NativeValue text(KtsValue written, String at) => switch (written) {
    KtsString(:final value) => NativeValue.found(value, at: at),
    KtsName(:final text) when text.startsWith('flutter.') => flutter.resolve(
      text,
      at,
    ),
    _ => _computed(written, at),
  };
  NativeValue number(KtsValue written, String at) => switch (written) {
    KtsInt(:final value) => NativeValue.found(value, at: at),
    KtsName(:final text) when text.startsWith('flutter.') => flutter.resolve(
      text,
      at,
    ),
    _ => _computed(written, at),
  };
  NativeValue javaVersion(KtsValue written, String at) =>
      _constant(written, at, const ['JavaVersion.']);
  NativeValue setting(
    List<String> path,
    _Convert convert, {
    List<String> oldNames = const [],
    String? absent,
  }) => _setting(app, path, convert, oldNames: oldNames, absent: absent);

  return NativeGroup({
    'plugins': _appliedPlugins(app),
    'namespace': setting(['android', 'namespace'], text),
    'applicationId': setting([
      'android',
      'defaultConfig',
      'applicationId',
    ], text),
    'compileSdk': setting(
      ['android', 'compileSdk'],
      number,
      oldNames: ['compileSdkVersion'],
    ),
    'minSdk': setting(
      ['android', 'defaultConfig', 'minSdk'],
      number,
      oldNames: ['minSdkVersion'],
    ),
    'targetSdk': setting(
      ['android', 'defaultConfig', 'targetSdk'],
      number,
      oldNames: ['targetSdkVersion'],
    ),
    'ndkVersion': setting(['android', 'ndkVersion'], text),
    'versionCode': setting(['android', 'defaultConfig', 'versionCode'], number),
    'versionName': setting(['android', 'defaultConfig', 'versionName'], text),
    'javaSourceCompatibility': setting([
      'android',
      'compileOptions',
      'sourceCompatibility',
    ], javaVersion),
    'javaTargetCompatibility': setting([
      'android',
      'compileOptions',
      'targetCompatibility',
    ], javaVersion),
    'kotlinJvmTarget': _kotlinJvmTarget(app),
    'releaseSigningConfig': setting(
      ['android', 'buildTypes', 'release', 'signingConfig'],
      _signing,
      absent: 'the release build type sets no signing config',
    ),
    'signingConfigs': _signingConfigs(app),
    'flavors': _flavors(app, text, number),
  });
}

/// [written] when it is a string, or a name starting with one of
/// [prefixes] (such as `JavaVersion.`).
NativeValue _constant(KtsValue written, String at, List<String> prefixes) =>
    switch (written) {
      KtsString(:final value) => NativeValue.found(value, at: at),
      KtsName(:final text) when prefixes.any(text.startsWith) =>
        NativeValue.found(text, at: at),
      _ => _computed(written, at),
    };

NativeValue _signing(KtsValue written, String at) => switch (written) {
  KtsCallValue(:final name, :final argument)
      when name == 'signingConfigs.getByName' ||
          name == 'signingConfigs.named' =>
    NativeValue.found(argument, at: at, expression: written.text),
  _ => _computed(written, at),
};

NativeValue _kotlinJvmTarget(_GradleFile app) {
  final script = app.script!;
  const paths = [
    ['kotlin', 'compilerOptions', 'jvmTarget'],
    ['android', 'kotlinOptions', 'jvmTarget'],
  ];
  final set = [
    for (final path in paths)
      if (script.assignmentsTo(path).isNotEmpty) path,
  ];
  if (set.isEmpty) {
    return NativeValue.absent('no Kotlin jvmTarget in ${app.kts.path}');
  }
  if (set.length > 1) {
    final lines = [
      for (final path in set)
        for (final assignment in script.assignmentsTo(path)) assignment.line,
    ]..sort();
    return NativeValue.unknown(
      'set more than once (lines ${lines.join(', ')})',
      at: app.kts.at(lines.first),
    );
  }
  return _setting(
    app,
    set.single,
    (written, at) => _constant(written, at, const [
      'JvmTarget.',
      'org.jetbrains.kotlin.gradle.dsl.JvmTarget.',
    ]),
  );
}

NativeValue _appliedPlugins(_GradleFile app) {
  final calls = [
    for (final call in app.script!.calls)
      if (ktsPathIs(call.plainPath, ['plugins'])) call,
  ];
  if (calls.isEmpty) {
    return NativeValue.absent('no plugin is applied in ${app.kts.path}');
  }
  final ids = <String>[];
  for (final call in calls) {
    final at = app.kts.at(call.line);
    if (call.conditional) {
      return NativeValue.unknown('a plugin is applied conditionally', at: at);
    }
    final id = switch ((call.name, call.argument)) {
      ('id', KtsString(:final value)) => value,
      ('kotlin', KtsString(:final value)) => 'org.jetbrains.kotlin.$value',
      _ => null,
    };
    if (id == null) {
      return NativeValue.unknown(
        'a plugin is applied with `${call.name}(${call.arguments})`, which '
        "Appstein doesn't evaluate",
        at: at,
      );
    }
    ids.add(id);
  }
  return NativeValue.found(ids, at: app.kts.at(calls.first.line));
}

NativeValue _signingConfigs(_GradleFile app) {
  final script = app.script!;
  const parent = ['android', 'signingConfigs'];
  final names = <String>{};
  final lines = <int>[];
  for (final block in script.blocksIn(parent)) {
    if (block.path.last == ktsOpaque) {
      return NativeValue.unknown(
        'a signing config is created with a computed name',
        at: app.kts.at(block.line),
      );
    }
    names.add(block.path.last);
    lines.add(block.line);
  }
  for (final call in script.calls) {
    if (!ktsPathIs(call.path, parent) || !_containerCalls.contains(call.name)) {
      continue;
    }
    final argument = call.argument;
    if (argument is! KtsString) {
      return NativeValue.unknown(
        'a signing config is created with a computed name',
        at: app.kts.at(call.line),
      );
    }
    names.add(argument.value);
    lines.add(call.line);
  }
  if (names.isEmpty) {
    return NativeValue.absent('no signing configs in ${app.kts.path}');
  }
  lines.sort();
  return NativeValue.found(names.toList()..sort(), at: app.kts.at(lines.first));
}

NativeNode _flavors(_GradleFile app, _Convert text, _Convert number) {
  const parent = ['android', 'productFlavors'];
  final firstLines = <String, int>{};
  for (final block in app.script!.blocksIn(parent)) {
    if (block.path.last == ktsOpaque) {
      return NativeValue.unknown(
        'a flavor is created with a computed name',
        at: app.kts.at(block.line),
      );
    }
    firstLines.putIfAbsent(block.path.last, () => block.line);
  }
  final keys = <String, _Convert>{
    'applicationId': text,
    'applicationIdSuffix': text,
    'versionNameSuffix': text,
    'dimension': text,
    'versionName': text,
    'minSdk': number,
    'targetSdk': number,
    'versionCode': number,
  };
  return NativeList([
    for (final MapEntry(key: name, value: line) in firstLines.entries)
      NativeEntry(name, {
        for (final MapEntry(key: key, value: convert) in keys.entries)
          if (_setting(app, [...parent, name, key], convert) case final value
              when value.status != NativeStatus.absent)
            key: value,
      }, at: app.kts.at(line)),
  ]);
}

NativeNode _manifest(NativeFile file) {
  if (!file.exists) return NativeValue.absent('no ${file.path}');
  final text = file.text;
  if (text == null) {
    return NativeValue.unknown(
      'could not be read: ${file.error}',
      at: file.path,
    );
  }
  final ManifestFacts facts;
  try {
    facts = readManifest(text);
  } on ManifestFormatException catch (error) {
    return NativeValue.unknown(
      'not valid XML: ${error.message}',
      at: switch (error.line) {
        final line? => file.at(line),
        null => file.path,
      },
    );
  }
  NativeValue attribute(ManifestAttribute? attribute, String name) =>
      attribute == null
      ? NativeValue.absent('no android:$name on <application>', at: file.path)
      : NativeValue.found(attribute.value, at: file.at(attribute.line));
  final byName = <String, List<ManifestPermission>>{};
  for (final permission in facts.permissions) {
    byName.putIfAbsent(permission.name, () => []).add(permission);
  }
  return NativeGroup({
    'label': attribute(facts.label, 'label'),
    'icon': attribute(facts.icon, 'icon'),
    'permissions': NativeList([
      for (final MapEntry(key: name, value: declared) in byName.entries)
        NativeEntry(name, {
          if (declared.first.maxSdkVersion case final max?)
            'maxSdkVersion': NativeValue.found(
              int.tryParse(max) ?? max,
              at: file.at(declared.first.line),
            ),
          if (declared.first.removed)
            'removed': NativeValue.found(
              true,
              at: file.at(declared.first.line),
            ),
          if (declared.first.sdk23)
            'sdk23': NativeValue.found(true, at: file.at(declared.first.line)),
          if (declared.length > 1)
            'declaredAgainAt': NativeValue.found([
              for (final again in declared.skip(1)) file.at(again.line),
            ], at: file.at(declared[1].line)),
        }, at: file.at(declared.first.line)),
    ]),
  });
}

/// What Flutter's Gradle plugin gives the `flutter.*` values (decision D3).
final class _FlutterValues {
  _FlutterValues(this.context, this.pubspec);

  final NativeContext context;
  final NativeFile pubspec;

  NativeValue resolve(String name, String at) => switch (name) {
    'flutter.compileSdkVersion' => _fromSdk(name, at, (t) => t.compileSdk),
    'flutter.minSdkVersion' => _fromSdk(name, at, (t) => t.minSdk),
    'flutter.targetSdkVersion' => _fromSdk(name, at, (t) => t.targetSdk),
    'flutter.ndkVersion' => _fromSdk(name, at, (t) => t.ndk),
    'flutter.versionCode' => _versionCode(at),
    'flutter.versionName' => _versionName(at),
    _ => NativeValue.unknown(
      "`$name` isn't a value Flutter's Gradle plugin defines",
      at: at,
    ),
  };

  NativeValue _fromSdk(
    String name,
    String at,
    Object Function(AndroidTemplate template) pick,
  ) {
    final android = context.android;
    if (android == null) {
      return NativeValue.unknown(
        "`$name`: this Flutter's value could not be read (see "
        "toolchain.json's fallbacks)",
        at: at,
      );
    }
    return NativeValue.found(
      pick(android.value.template),
      at: at,
      expression: name,
      resolvedFrom: android.source == ToolchainSource.sdk ? 'flutter' : 'notes',
    );
  }

  /// `pubspec.yaml`'s `version:` as Flutter reads it
  /// (`FlutterManifest.appVersion`): null when missing or not a valid
  /// version.
  ({String? version, String? written, int? line}) _version() {
    final node = loadPubspec(pubspec)?.nodes['version'];
    final written = node?.value?.toString();
    if (node == null || written == null) {
      return (version: null, written: null, line: null);
    }
    try {
      return (
        version: Version.parse(written).toString(),
        written: written,
        line: yamlLine(node),
      );
    } on FormatException {
      return (version: null, written: written, line: yamlLine(node));
    }
  }

  static String _defaultNote(String? written, String? version) =>
      written == null
      ? 'pubspec.yaml has no version'
      : version == null
      ? "pubspec.yaml's version `$written` isn't valid"
      : "pubspec.yaml's version has no build number (`+N`)";

  /// The part after `+`, digits only, at least 1
  /// (`validatedBuildNumberForPlatform`); without one, Flutter's Gradle
  /// plugin uses 1 (`FlutterPlugin.kt`).
  NativeValue _versionCode(String at) {
    final read = _version();
    final version = read.version;
    if (version == null || !version.contains('+')) {
      return NativeValue.found(
        1,
        at: at,
        expression: 'flutter.versionCode',
        resolvedFrom: 'default',
        note: _defaultNote(read.written, version),
      );
    }
    final digits = version.split('+')[1].replaceAll(RegExp('[^0-9]'), '');
    final number = int.tryParse(digits) ?? 0;
    return NativeValue.found(
      number < 1 ? 1 : number,
      at: at,
      expression: 'flutter.versionCode',
      resolvedFrom: 'pubspec.yaml:${read.line}',
    );
  }

  /// The part before `+`; without a valid version, Flutter's Gradle plugin
  /// uses `1.0` (`FlutterPlugin.kt`).
  NativeValue _versionName(String at) {
    final read = _version();
    final version = read.version;
    if (version == null) {
      return NativeValue.found(
        '1.0',
        at: at,
        expression: 'flutter.versionName',
        resolvedFrom: 'default',
        note: _defaultNote(read.written, null),
      );
    }
    return NativeValue.found(
      version.split('+').first,
      at: at,
      expression: 'flutter.versionName',
      resolvedFrom: 'pubspec.yaml:${read.line}',
    );
  }
}
