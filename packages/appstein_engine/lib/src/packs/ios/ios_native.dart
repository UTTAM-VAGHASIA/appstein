import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../../android/flutter_settings.dart';
import '../../native/native_extractor.dart';
import '../../native/native_files.dart';
import 'info_plist_reader.dart';
import 'ios_files.dart';
import 'pbxproj_reader.dart';
import 'plist_value.dart';
import 'swiftpm_setting.dart';

const _infoPlistPath = 'ios/Runner/Info.plist';
const _pbxprojPath = 'ios/Runner.xcodeproj/project.pbxproj';
const _packagePath =
    'ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/'
    'Package.swift';

/// Builds the `ios` section of `native.json` (spec §6.5) from the project's
/// `ios/` files, `pubspec.yaml`, and the SwiftPM settings Flutter reads
/// from outside the project. It never throws for the project's own
/// problems.
NativeSection readIosNative(NativeContext context) {
  final root = context.projectRoot;
  if (!Directory(p.join(root, 'ios')).existsSync()) {
    return const NativeSection(NativeValue.absent('no ios/ folder'), {});
  }
  final inputs = <String, List<int>?>{};
  NativeFile read(String path) {
    final file = readNativeFile(root, path);
    inputs[file.input.key] = file.input.value;
    return file;
  }

  final pubspec = read('pubspec.yaml');
  final global = readFlutterSettings(
    context.environment,
  )[swiftPackageManagerSetting];
  final variable = rawVariable(
    context.environment,
    swiftPackageManagerVariable,
  );
  // The global value and the environment variable decide SwiftPM, so both
  // join the input hash (a missing one is null).
  inputs['flutter-config:$swiftPackageManagerSetting'] = global == null
      ? null
      : utf8.encode(jsonEncode(global));
  inputs['env:$swiftPackageManagerVariable'] = variable == null
      ? null
      : utf8.encode(variable);
  final loaded = loadPubspec(pubspec);
  // pubspec.yaml's `flutter: config:` decides first, so a pubspec that
  // exists but can't be loaded leaves the decision unknown.
  final enabled = pubspec.exists && loaded == null
      ? const NativeValue.unknown(
          "pubspec.yaml can't be read, and its `flutter: config:` decides "
          'first',
          at: 'pubspec.yaml',
        )
      : swiftPackageManagerEnabled(
          pubspec: loaded,
          global: global,
          variable: variable,
          flutterVersion: context.flutterVersion,
          channel: context.channel,
        );
  return NativeSection(
    NativeGroup({
      'infoPlist': _infoPlist(read(_infoPlistPath)),
      'xcode': _xcode(read(_pbxprojPath)),
      'swiftPackageManager': NativeGroup({'enabled': enabled}),
      'generatedPackage': _generatedPackage(read(_packagePath), enabled),
      'podfile': _podfile(read('ios/Podfile'), read('ios/Podfile.lock')),
    }),
    inputs,
  );
}

PlistDict? _dict(PlistValue? value) => value is PlistDict ? value : null;

String? _text(PlistValue? value) => value is PlistString ? value.value : null;

NativeValue _unreadable(NativeFile file) =>
    NativeValue.unknown('could not be read: ${file.error}', at: file.path);

NativeNode _infoPlist(NativeFile file) {
  if (!file.exists) return NativeValue.absent('no ${file.path}');
  final text = file.text;
  if (text == null) return _unreadable(file);
  final PlistDict dict;
  try {
    dict = readXmlPlist(text);
  } on PlistFormatException catch (error) {
    return NativeValue.unknown(
      error.message,
      at: switch (error.line) {
        final line? => file.at(line),
        null => file.path,
      },
    );
  }
  NativeValue string(String key) => switch (dict.entries[key]) {
    PlistString(:final value, :final line) => NativeValue.found(
      value,
      at: file.at(line),
      note: _variablesNote(value),
    ),
    null => NativeValue.absent('no $key in ${file.path}'),
    final other => NativeValue.unknown(
      "$key isn't a string",
      at: file.at(other.line),
    ),
  };
  final scene = dict.entries['UIApplicationSceneManifest'];
  return NativeGroup({
    'bundleIdentifier': string('CFBundleIdentifier'),
    'displayName': string('CFBundleDisplayName'),
    'bundleName': string('CFBundleName'),
    'shortVersionString': string('CFBundleShortVersionString'),
    'bundleVersion': string('CFBundleVersion'),
    'sceneManifest': scene == null
        ? NativeValue.absent('no UIApplicationSceneManifest in ${file.path}')
        : NativeValue.found(
            true,
            at: file.at(dict.keyLines['UIApplicationSceneManifest']!),
          ),
    'sceneDelegate': _sceneDelegate(_dict(scene), file),
    'usageDescriptions': NativeList([
      for (final MapEntry(key: key, value: description) in dict.entries.entries)
        if (key.endsWith('UsageDescription'))
          NativeEntry(key, {
            'text': description is PlistString
                ? NativeValue.found(
                    description.value,
                    at: file.at(description.line),
                    note: _variablesNote(description.value),
                  )
                : NativeValue.unknown(
                    "isn't a string",
                    at: file.at(description.line),
                  ),
          }, at: file.at(dict.keyLines[key]!)),
    ]),
  });
}

NativeValue _sceneDelegate(PlistDict? scene, NativeFile file) {
  final configurations = _dict(scene?.entries['UISceneConfigurations']);
  final roles = configurations?.entries['UIWindowSceneSessionRoleApplication'];
  final first = roles is PlistArray && roles.items.isNotEmpty
      ? _dict(roles.items.first)
      : null;
  final delegate = first?.entries['UISceneDelegateClassName'];
  if (delegate is PlistString) {
    return NativeValue.found(
      delegate.value,
      at: file.at(delegate.line),
      note: _variablesNote(delegate.value),
    );
  }
  return NativeValue.absent(
    scene == null
        ? 'no scene manifest in ${file.path}'
        : 'no UISceneDelegateClassName in the scene manifest',
  );
}

NativeNode _xcode(NativeFile file) {
  if (!file.exists) return NativeValue.absent('no ${file.path}');
  final text = file.text;
  if (text == null) return _unreadable(file);
  final integrated = NativeValue.found(
    text.contains('FlutterGeneratedPluginSwiftPackage'),
    at: file.path,
  );
  final PlistDict root;
  try {
    root = readPbxproj(text);
  } on PlistFormatException catch (error) {
    return NativeGroup({
      'swiftPackageIntegrated': integrated,
      'configurations': NativeValue.unknown(
        error.message,
        at: switch (error.line) {
          final line? => file.at(line),
          null => file.path,
        },
      ),
    });
  }
  return NativeGroup({
    'swiftPackageIntegrated': integrated,
    'configurations': _configurations(root, file),
  });
}

NativeNode _configurations(PlistDict root, NativeFile file) {
  final objects = _dict(root.entries['objects']);
  final project = _dict(objects?.entries[_text(root.entries['rootObject'])]);
  if (objects == null || project == null) {
    return NativeValue.unknown(
      'project.pbxproj has no project object',
      at: file.path,
    );
  }
  PlistDict? object(PlistValue? id) => _dict(objects.entries[_text(id)]);
  Map<String, PlistDict> configurationsOf(PlistDict owner) {
    final list = object(owner.entries['buildConfigurationList']);
    final ids = list?.entries['buildConfigurations'];
    return {
      for (final id in ids is PlistArray ? ids.items : const <PlistValue>[])
        ?_text(object(id)?.entries['name']): ?object(id),
    };
  }

  final targets = project.entries['targets'];
  final runner = [
    for (final id
        in targets is PlistArray ? targets.items : const <PlistValue>[])
      if (object(id) case final target?
          when _text(target.entries['isa']) == 'PBXNativeTarget' &&
              _text(target.entries['name']) == 'Runner')
        target,
  ];
  if (runner.isEmpty) {
    return NativeValue.unknown(
      'project.pbxproj has no Runner target',
      at: file.path,
    );
  }
  final runnerList = object(runner.first.entries['buildConfigurationList']);
  if (runnerList?.entries['buildConfigurations'] is! PlistArray) {
    return NativeValue.unknown(
      'the Runner target has no build configuration list',
      at: file.at(runner.first.line),
    );
  }
  final projectConfigurations = configurationsOf(project);
  return NativeList([
    for (final MapEntry(key: name, value: configuration) in configurationsOf(
      runner.first,
    ).entries)
      NativeEntry(name, {
        for (final (part, key) in const [
          ('bundleIdentifier', 'PRODUCT_BUNDLE_IDENTIFIER'),
          ('deploymentTarget', 'IPHONEOS_DEPLOYMENT_TARGET'),
          ('swiftVersion', 'SWIFT_VERSION'),
        ])
          part: _buildSetting(
            configuration,
            projectConfigurations[name],
            key,
            file,
          ),
        'developmentTeamSet': _team(
          configuration,
          projectConfigurations[name],
          file,
        ),
      }, at: file.at(configuration.line)),
  ]);
}

/// [key] of the Runner configuration [target], or of the project's
/// configuration of the same name (decision D9).
({PlistValue? value, bool inherited}) _lookup(
  PlistDict target,
  PlistDict? project,
  String key,
) {
  final own = _dict(target.entries['buildSettings'])?.entries[key];
  if (own != null) return (value: own, inherited: false);
  return (
    value: _dict(project?.entries['buildSettings'])?.entries[key],
    inherited: true,
  );
}

NativeValue _notInProject(String key, NativeFile file) => NativeValue.unknown(
  '$key is not in project.pbxproj; it may come from an .xcconfig file',
  at: file.path,
);

NativeValue _buildSetting(
  PlistDict target,
  PlistDict? project,
  String key,
  NativeFile file,
) {
  final (:value, :inherited) = _lookup(target, project, key);
  if (value == null) return _notInProject(key, file);
  final at = file.at(value.line);
  if (value is! PlistString) {
    return NativeValue.unknown("$key isn't a single value", at: at);
  }
  final notes = [
    ?(inherited ? _projectLevelNote(target) : null),
    ?_variablesNote(value.value),
  ];
  return NativeValue.found(
    value.value,
    at: at,
    note: notes.isEmpty ? null : notes.join('; '),
  );
}

/// The note for a value that comes from the project's build settings.
/// Xcode ranks the Runner target's own `.xcconfig` file
/// (`baseConfigurationReference`, such as `Flutter/Release.xcconfig`) above
/// the project's settings, so when there is one, it may override the value.
String _projectLevelNote(PlistDict target) =>
    target.entries['baseConfigurationReference'] == null
    ? 'set at project level'
    : "set at project level; the target's .xcconfig file can override it";

/// The note for a [value] that names Xcode build variables, such as
/// `$(PRODUCT_BUNDLE_IDENTIFIER)`: the text isn't the final value.
String? _variablesNote(String value) =>
    value.contains(r'$(') ? 'uses Xcode build variables' : null;

/// Whether a development team is set; the team's ID is never recorded.
NativeValue _team(PlistDict target, PlistDict? project, NativeFile file) {
  final (:value, :inherited) = _lookup(target, project, 'DEVELOPMENT_TEAM');
  if (value == null) return _notInProject('DEVELOPMENT_TEAM', file);
  final at = file.at(value.line);
  if (value is! PlistString) {
    return NativeValue.unknown("DEVELOPMENT_TEAM isn't a single value", at: at);
  }
  return NativeValue.found(
    value.value.isNotEmpty,
    at: at,
    note: inherited ? _projectLevelNote(target) : null,
  );
}

NativeNode _generatedPackage(NativeFile file, NativeValue enabled) {
  if (!file.exists) {
    return NativeValue.absent(switch (enabled.value) {
      true => 'not generated yet: `flutter pub get` writes it',
      false => "SwiftPM is off, so Flutter doesn't generate it",
      _ => '`flutter pub get` writes it when SwiftPM is on',
    });
  }
  final text = file.text;
  if (text == null) return _unreadable(file);
  final facts = readGeneratedPackage(text);
  return NativeGroup({
    'iosVersion': switch ((facts.iosVersion, facts.iosVersionLine)) {
      (final version?, final line?) => NativeValue.found(
        version,
        at: file.at(line),
      ),
      _ => NativeValue.unknown(
        'no .iOS("…") platform in the generated Package.swift',
        at: file.path,
      ),
    },
    'plugins': facts.hasFlutterFramework
        ? NativeValue.found(facts.plugins, at: file.path)
        : NativeValue.unknown(
            'written without Swift Package Manager in effect: Flutter lists '
            'the plugins here only on a Mac with Xcode 15 or later',
            at: file.path,
          ),
  });
}

NativeNode _podfile(NativeFile file, NativeFile lock) {
  if (!file.exists) {
    return const NativeValue.absent(
      'no ios/Podfile: Flutter creates one only when a plugin needs '
      'CocoaPods',
    );
  }
  final text = file.text;
  if (text == null) return _unreadable(file);
  final facts = readPodfile(text);
  return NativeGroup({
    'platform': switch ((facts.version, facts.line)) {
      (_, final line?) when facts.uncertain != null => NativeValue.unknown(
        facts.uncertain!,
        at: file.at(line),
      ),
      (final version?, final line?) => NativeValue.found(
        version,
        at: file.at(line),
      ),
      (null, final line?) when facts.isExpression => NativeValue.unknown(
        'set by a Ruby expression',
        at: file.at(line),
      ),
      (null, final line?) => NativeValue.absent(
        '`platform :ios` names no version',
        at: file.at(line),
      ),
      _ => NativeValue.absent(
        'no `platform :ios` line (CocoaPods then uses its default)',
        at: file.path,
      ),
    },
    'lockPresent': NativeValue.found(lock.exists, at: lock.path),
  });
}
