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
    final lines = <int>{
      for (final assignment in script.assignmentsTo([...parent, old]))
        assignment.line,
      for (final call in script.callsTo(parent, old)) call.line,
      // The old setter form: `setMinSdkVersion(21)`.
      for (final call in script.callsTo(parent, _setter(old))) call.line,
    }.toList()..sort();
    if (lines.isNotEmpty) {
      return NativeValue.unknown(
        'set with the old name `$old` (line ${lines.join(', ')})',
        at: file.kts.at(lines.first),
      );
    }
  }
  // A body the reader reads twice (see `kts_reader.dart`) gives the same
  // line twice: keep one assignment per line.
  final seenLines = <int>{};
  final found = [
    for (final assignment in script.assignmentsTo(path))
      if (seenLines.add(assignment.line)) assignment,
  ];
  if (found.isEmpty) {
    if (_setElsewhere(script, path) case final line?) {
      return NativeValue.unknown(
        "set where Appstein doesn't follow (line $line)",
        at: file.kts.at(line),
      );
    }
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

/// The old setter form of [name]: `minSdkVersion` is `setMinSdkVersion`.
String _setter(String name) =>
    'set${name[0].toUpperCase()}${name.substring(1)}';

/// The property a setter call such as `setNamespace("x")` sets (`namespace`),
/// or [name] itself when it isn't one.
String _setterKey(String name) =>
    name.length > 3 &&
        name.startsWith('set') &&
        name[3] == name[3].toUpperCase() &&
        name[3] != name[3].toLowerCase()
    ? '${name[3].toLowerCase()}${name.substring(4)}'
    : name;

/// The 1-based line of the first assignment, call or block in [script] that
/// sets [path]'s key somewhere the reader can't place at [path] itself
/// (inside `tasks.withType<…>().configureEach { }`, a scope function, a
/// different wrapper block, AGP's `minSdk { version = release(24) }` block
/// form, an old `setNamespace("x")` call), or null when there is none. It
/// matches the key and the block just above it, so a flavor's own `minSdk`
/// isn't taken for `defaultConfig`'s. Used so a value is never reported
/// `absent` when it may be set in a place Appstein doesn't follow.
int? _setElsewhere(KtsScript script, List<String> path) {
  // [raw] keeps the `?` segments (a body the reader can't place); a
  // conditional one also matches when the segment above the key is `?` or
  // any block of [path] (`getByName("release").apply { signingConfig = … }`).
  // `it` and `this` are the receiver itself, so they are transparent.
  bool matches(List<String> raw) {
    final full = [
      for (final segment in raw)
        if (segment != ktsOpaque && segment != 'it' && segment != 'this')
          segment,
    ];
    if (full.isEmpty || full.last != path.last) return false;
    if (full.length == 1 || path.length == 1) return true;
    if (full[full.length - 2] == path[path.length - 2]) return true;
    if (raw.length < 2 || !raw.contains(ktsOpaque)) return false;
    // Conditional: the block that holds the key (ignoring `?`) must be one
    // of [path]'s, so a sibling block's own key isn't taken for this one's.
    return path.contains(full[full.length - 2]);
  }

  final lines = [
    for (final assignment in script.assignments)
      if (matches(assignment.path)) assignment.line,
    for (final call in script.calls)
      // `jvmTarget.set(x)` sets `jvmTarget`; `setNamespace(x)` sets
      // `namespace`; any other call is its own name.
      if (matches(
        call.name == 'set' || call.name == 'assign'
            ? call.path
            : [...call.path, _setterKey(call.name)],
      ))
        call.line,
    // `compileSdk { version = release(36) }`.
    for (final block in script.blocks)
      if (matches(block.path)) block.line,
  ]..sort();
  return lines.isEmpty ? null : lines.first;
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
  // Declarations Appstein can't name (`alias(…)`, `id(someVal)`).
  final unnamed = <({String what, String at})>[];
  for (final file in [settings, rootBuild]) {
    final script = file.script;
    if (script == null) continue;
    for (final call in script.calls) {
      if (call.plainPath.isEmpty || call.plainPath.last != 'plugins') continue;
      final at = file.kts.at(call.line);
      final called = switch ((call.name, call.argument)) {
        ('id', KtsString(:final value)) => value,
        ('kotlin', KtsString(:final value)) => 'org.jetbrains.kotlin.$value',
        _ => null,
      };
      if (called == null) {
        unnamed.add((what: '${call.name}(${call.arguments})', at: at));
        continue;
      }
      if (called != id) continue;
      found.add((
        version: call.infix['version'],
        at: at,
        conditional: call.conditional || !ktsPathIs(call.path, ['plugins']),
      ));
    }
    if (classpath == null) continue;
    final prefix = '$classpath:';
    for (final call in script.callsTo([
      'buildscript',
      'dependencies',
    ], 'classpath')) {
      final at = file.kts.at(call.line);
      final argument = call.argument;
      if (!call.arguments.contains(prefix)) {
        if (argument is! KtsString) {
          unnamed.add((what: 'classpath(${call.arguments})', at: at));
        }
        continue;
      }
      found.add((
        version: argument is KtsString && argument.value.startsWith(prefix)
            ? KtsString(argument.value.substring(prefix.length), argument.text)
            : KtsComputed(call.arguments),
        at: at,
        conditional:
            call.conditional ||
            !ktsPathIs(call.path, ['buildscript', 'dependencies']),
      ));
    }
  }
  if (found.isEmpty) {
    if (unnamed.isNotEmpty) {
      return NativeValue.unknown(
        'declared with `${unnamed.first.what}`, a plugin or dependency '
        "Appstein can't name or evaluate",
        at: unnamed.first.at,
      );
    }
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
    // The reader doesn't see a `.version("…")` call chain, so a declaration
    // with no plain `version "…"` is never reported as having none.
    null => NativeValue.unknown(
      'declared without a plain `version "…"` (a `.version(…)` call chain '
      "isn't read)",
      at: only.at,
    ),
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

  final flavors = _flavors(app, text, number);
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
    'releaseSigningConfig': _releaseSigning(
      setting(
        ['android', 'buildTypes', 'release', 'signingConfig'],
        _signing,
        absent: 'the release build type sets no signing config',
      ),
      setting(['android', 'defaultConfig', 'signingConfig'], _signing),
      _flavorSigning(app, flavors),
    ),
    'signingConfigs': _signingConfigs(app),
    'flavors': flavors,
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

/// Unknown when a flavor sets (or may set) its own signing config: AGP
/// picks the build type's, then the flavor's, then `defaultConfig`'s, so
/// the release builds of that flavor aren't signed with `defaultConfig`'s.
NativeValue? _flavorSigning(_GradleFile app, NativeNode flavors) {
  if (flavors is NativeValue) {
    return NativeValue.unknown(
      'release sets no signing config, and flavors may set their own '
      '(the flavor list is unknown)',
      at: flavors.at,
    );
  }
  final script = app.script!;
  final lines = [
    for (final assignment in script.assignments)
      if (assignment.plainPath.contains('productFlavors') &&
          assignment.plainPath.last == 'signingConfig')
        assignment.line,
    for (final call in script.calls)
      if (call.plainPath.contains('productFlavors') &&
          call.name == 'signingConfig')
        call.line,
  ]..sort();
  if (lines.isEmpty) return null;
  return NativeValue.unknown(
    'release sets no signing config, and flavors set their own signing '
    'configs (line ${lines.first})',
    at: app.kts.at(lines.first),
  );
}

/// The release signing config: the release build type's, or, when it sets
/// none, `defaultConfig`'s (AGP gives it to every build type that sets no
/// signing config of its own).
NativeValue _releaseSigning(
  NativeValue release,
  NativeValue fromDefault,
  NativeValue? flavorsSign,
) {
  if (release.status != NativeStatus.absent) return release;
  if (flavorsSign != null) return flavorsSign;
  return switch (fromDefault.status) {
    NativeStatus.found => NativeValue.found(
      fromDefault.value!,
      at: fromDefault.at,
      expression: fromDefault.expression,
      note:
          'set in defaultConfig; the release build type sets none, so it '
          'uses this one',
    ),
    NativeStatus.unknown => NativeValue.unknown(
      'release sets no signing config, and defaultConfig sets one that '
      "Appstein can't read: ${fromDefault.reason}",
      at: fromDefault.at,
    ),
    _ => release,
  };
}

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
  NativeValue convert(KtsValue written, String at) => _constant(
    written,
    at,
    const ['JvmTarget.', 'org.jetbrains.kotlin.gradle.dsl.JvmTarget.'],
  );
  // `jvmTarget = x` and `jvmTarget.set(x)` / `jvmTarget.assign(x)`.
  final everySetting =
      <({List<String> path, int line, KtsCall? call, bool plain})>[
        for (final path in paths) ...[
          for (final assignment in script.assignmentsTo(path))
            (path: path, line: assignment.line, call: null, plain: true),
          for (final name in const ['set', 'assign'])
            for (final call in script.callsTo(path, name))
              (
                path: path,
                line: call.line,
                call: call,
                plain: ktsPathIs(call.path, path),
              ),
        ],
      ];
  // A body the reader reads twice gives the same line twice.
  final seenLines = <int>{};
  final settings = [
    for (final setting in everySetting)
      if (seenLines.add(setting.line)) setting,
  ];
  if (settings.isEmpty) {
    for (final call in script.calls) {
      if (call.name == 'jvmToolchain') {
        return NativeValue.unknown(
          'set by jvmToolchain(${call.arguments}) (line ${call.line})',
          at: app.kts.at(call.line),
        );
      }
    }
    // `kotlin { jvmToolchain { … } }`, `java { toolchain { … } }`.
    final toolchain = [
      for (final block in script.blocks)
        if (ktsPathIs(block.path, ['kotlin', 'jvmToolchain']) ||
            ktsPathIs(block.path, ['java', 'toolchain']))
          block.line,
      for (final assignment in script.assignments)
        if (assignment.plainPath.contains('toolchain') ||
            assignment.plainPath.contains('jvmToolchain'))
          assignment.line,
      for (final call in script.calls)
        if (call.plainPath.contains('toolchain') ||
            call.plainPath.contains('jvmToolchain'))
          call.line,
    ]..sort();
    if (toolchain.isNotEmpty) {
      return NativeValue.unknown(
        'set by a Java toolchain (line ${toolchain.first})',
        at: app.kts.at(toolchain.first),
      );
    }
    for (final path in paths) {
      if (_setElsewhere(script, path) case final line?) {
        return NativeValue.unknown(
          "set where Appstein doesn't follow (line $line)",
          at: app.kts.at(line),
        );
      }
    }
    return NativeValue.absent('no Kotlin jvmTarget in ${app.kts.path}');
  }
  if (settings.length > 1) {
    final lines = [for (final setting in settings) setting.line]..sort();
    return NativeValue.unknown(
      'set more than once (lines ${lines.join(', ')})',
      at: app.kts.at(lines.first),
    );
  }
  final only = settings.single;
  final call = only.call;
  if (call == null) return _setting(app, only.path, convert);
  final at = app.kts.at(only.line);
  if (!only.plain || call.conditional) {
    return NativeValue.unknown(
      "set where Appstein doesn't follow (line ${only.line})",
      at: at,
    );
  }
  return convert(call.argument ?? KtsComputed(call.arguments), at);
}

NativeValue _appliedPlugins(_GradleFile app) {
  final calls = [
    for (final call in app.script!.calls)
      if (ktsPathIs(call.plainPath, ['plugins'])) call,
  ];
  for (final call in app.script!.calls) {
    if (call.name == 'apply') {
      return NativeValue.unknown(
        'a plugin is applied with `apply(${call.arguments})`, which '
        "Appstein doesn't evaluate",
        at: app.kts.at(call.line),
      );
    }
  }
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

/// The entries of the Gradle container at [parent] (`signingConfigs`,
/// `productFlavors`), each with the first line it appears on: from
/// `create("x") { }` blocks and from `create("x")`, `register("x")`,
/// `getByName("x")`… calls. Or the unknown value when something is declared
/// there that Appstein can't name, or doesn't follow (a computed name, an
/// `if`, a lambda, `afterEvaluate { }`, `val x by creating`).
({Map<String, int>? entries, NativeValue? unknown}) _containerEntries(
  _GradleFile app,
  List<String> parent,
  String what,
) {
  final script = app.script!;
  final entries = <String, int>{};
  final generic =
      '$what is declared in a way Appstein '
      "doesn't follow (`if`, lambda, `afterEvaluate { }`, `val x by creating`)";
  final computed = '$what is created with a computed name';
  NativeValue unknown(String reason, int line) =>
      NativeValue.unknown(reason, at: app.kts.at(line));
  bool computedCall(KtsCall call) =>
      _containerCalls.contains(call.name) &&
      ktsPathIs(call.path, parent) &&
      call.argument is! KtsString;
  for (final block in script.blocksIn(parent)) {
    if (block.path.last == ktsOpaque) {
      // The reader can't tell `create(name) { }` from an `if { }` body.
      return (
        entries: null,
        unknown: unknown('$computed, or $generic', block.line),
      );
    }
    entries.update(
      block.path.last,
      (line) => line < block.line ? line : block.line,
      ifAbsent: () => block.line,
    );
  }
  for (final name in _containerCalls) {
    for (final call in script.callsTo(parent, name)) {
      final argument = call.argument;
      if (!ktsPathIs(call.path, parent) || argument is! KtsString) {
        return (
          entries: null,
          unknown: unknown(computedCall(call) ? computed : generic, call.line),
        );
      }
      entries.update(
        argument.value,
        (line) => line < call.line ? line : call.line,
        ifAbsent: () => call.line,
      );
    }
  }
  return (entries: entries, unknown: null);
}

NativeValue _signingConfigs(_GradleFile app) {
  final result = _containerEntries(app, const [
    'android',
    'signingConfigs',
  ], 'a signing config');
  if (result.unknown case final unknown?) return unknown;
  final entries = result.entries!;
  if (entries.isEmpty) {
    return NativeValue.absent('no signing configs in ${app.kts.path}');
  }
  return NativeValue.found(
    entries.keys.toList()..sort(),
    at: app.kts.at(entries.values.reduce((a, b) => a < b ? a : b)),
  );
}

NativeNode _flavors(_GradleFile app, _Convert text, _Convert number) {
  const parent = ['android', 'productFlavors'];
  final result = _containerEntries(app, parent, 'a flavor');
  if (result.unknown case final unknown?) return unknown;
  final keys = <String, ({_Convert convert, List<String> oldNames})>{
    'applicationId': (convert: text, oldNames: const []),
    'applicationIdSuffix': (convert: text, oldNames: const []),
    'versionNameSuffix': (convert: text, oldNames: const []),
    'dimension': (convert: text, oldNames: const []),
    'versionName': (convert: text, oldNames: const []),
    'minSdk': (convert: number, oldNames: const ['minSdkVersion']),
    'targetSdk': (convert: number, oldNames: const ['targetSdkVersion']),
    'versionCode': (convert: number, oldNames: const []),
  };
  return NativeList([
    for (final MapEntry(key: name, value: line) in result.entries!.entries)
      NativeEntry(name, {
        for (final MapEntry(key: key, value: spec) in keys.entries)
          if (_setting(
                app,
                [...parent, name, key],
                spec.convert,
                oldNames: spec.oldNames,
              )
              case final value when value.status != NativeStatus.absent)
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

  /// Why `pubspec.yaml` can't give [name] its value (missing, unreadable,
  /// not UTF-8, not a YAML map), or null when it can be read. Never a
  /// default: Flutter's defaults apply only to a pubspec that was read.
  NativeValue? _pubspecProblem(String name) {
    if (loadPubspec(pubspec) != null) return null;
    final why = !pubspec.exists
        ? "doesn't exist"
        : pubspec.error != null
        ? 'could not be read: ${pubspec.error}'
        : 'could not be read: not a valid YAML map';
    return NativeValue.unknown(
      'pubspec.yaml $why (needed for `$name`)',
      at: pubspec.path,
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
    if (_pubspecProblem('flutter.versionCode') case final problem?) {
      return problem;
    }
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
    if (_pubspecProblem('flutter.versionName') case final problem?) {
      return problem;
    }
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
