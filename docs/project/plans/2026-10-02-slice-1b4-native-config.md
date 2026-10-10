# Slice 1b.4: Native config map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync` also writes `.appstein/map/native.json`: the Android and iOS setup of the project (IDs, SDK levels, Gradle, AGP and Kotlin versions, permissions, the iOS deployment target, the SwiftPM state), each value with where it was found, and `unknown` with a reason whenever Appstein can't read it plainly. Nothing is guessed.

**Architecture:**
- **Protocol:** `NativeConfig` is a small tree: values (`found`, `unknown`, `absent`, `error`), groups with fixed names, and lists of entries the project names (flavors, permissions, Xcode configurations).
- **Engine core (`lib/src/native/`):**
  - `NativeExtractor` is the new pack seam; it gets a `NativeContext` (project root, Flutter version and channel, Flutter's Android values, the machine), never the Dart analysis.
  - `NativeSync` runs the platform packs' extractors and builds one `GeneratedFile`.
- **`android` pack (`lib/src/packs/android/`):** readers for Gradle Kotlin scripts, `.properties` files and `AndroidManifest.xml`, and the section builder.
- **`ios` pack (`lib/src/packs/ios/`):** readers for XML property lists, `project.pbxproj`, the generated `Package.swift` and the `Podfile`; Flutter's SwiftPM setting; and the section builder.
- **Wiring:**
  - `KnowledgeSync` runs `NativeSync` after `MapSync`, whether or not the map was skipped, and writes `native.json` under the same lock;
  - the CLI's `packsFor` adds the platform packs from `packs.platforms`.

**Tech Stack:** Dart 3.12+ (Flutter 3.47.5 via FVM), `package:xml` ^6.6.1 (new; the version `flutter_tools` itself pins), `package:yaml`, `package:pub_semver`, `package:path`, `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. This plan implements:
- §6.5 "Native config" and "Resolution", as edited in commit `b511c72` (owner-approved E1–E5);
- §6.2: `map/native.json` and its metadata;
- §10: platform packs and `nativeExtractor`;
- §15: determinism, Windows paths, offline, and the 30 s full-sync target.

The checks that judge these values are slice 1d (§9.2); `native.md` is slice 1c (§6.9); INDEX.md's IDs are slice 1b.6 (§6.3).

## Global Constraints

- **Commands:** run every Dart command through FVM: `fvm dart …`. The repo pins Flutter 3.47.5 (Dart 3.13.4); packages declare `sdk: ^3.12.0`. CI also runs the unit tests on Flutter 3.44 (Dart 3.12), so no unit test may depend on the real Flutter SDK.
- **Boundaries (spec §5.1):**
  - `appstein_protocol` depends on nothing internal; `appstein_engine` only on `appstein_protocol`; `appstein_cli` on the engine and protocol.
  - The engine core never imports a pack. `lib/src/native/` is engine core.
  - The `android` pack never imports the `ios` pack, and the reverse. Shared helpers live in `lib/src/native/`.
  - `layer_imports` enforces all this (tags in the repo's `analysis_options.yaml`).
- **Docs and analysis:** every public API has a `///` doc comment (`public_member_api_docs`). These must pass from the repo root:
  - `fvm dart analyze --fatal-infos`;
  - `fvm dart format --output=none --set-exit-if-changed .`;
  - `fvm dart run dependency_validator`.
- **Byte order marks:** no raw U+FEFF byte in any `.dart` file. Code that strips a BOM compares `text.codeUnitAt(0) == 0xFEFF`; tests that need a BOM write the bytes `0xEF, 0xBB, 0xBF`. Never type the BOM escape sequence.
- **Windows is first-class:**
  - every file-system test uses `tempDir()` (`packages/appstein_engine/test/support/temp.dart`), whose path holds a space and a non-ASCII character;
  - every `at` in `native.json` is relative to the project, with `/`;
  - generated text uses `\n` on every OS; readers accept `\r\n`.
- **Never guess (spec §6.5):** a value is `found` only when the file states it plainly. Computed, set twice, set conditionally, old forms, unreadable files and unknown Flutter variables are `unknown` with a reason. Missing is `absent` with a reason.
- **No secrets (spec §6.5):** never record signing passwords, keystore paths, `gradle.properties` keys beyond the listed ones, a development team ID (only whether one is set), or any machine path (the generated `Package.swift` holds absolute plugin paths; only plugin names are recorded).
- **Determinism (§15):** the same inputs give byte-identical `native.json` on every OS. Lists the project names are sorted by name; `canonicalJson` sorts keys. No file timestamps are read.
- **No network in unit tests.** Only the real-SDK integration test (Task 9) runs `flutter create` and `flutter pub get`.
- **Fixtures:** every fixture file ends in `.fixture`, so the repo's analyzer, formatter and graph ignore it; `copyFixtureTree` drops the suffix. Golden files end in `.golden`.
- **Tests stay in temp folders:** tests never write into the repo, `graphify-out/` or `.git/hooks`. The single exception is `APPSTEIN_UPDATE_GOLDENS=1`, which a person runs on purpose.
- **Tests never read the real machine's Flutter settings:** every `NativeContext` and `KnowledgeSync` in a unit test uses `fakeEnvironment`, and tests that need the global settings point `APPDATA` and `HOME` at a temp folder.
- **Commits:** subagents never commit. The controller commits each task after its review, with the session's trailer lines, behind the BOM byte scan: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` must print nothing.
- **Subagents:** at most 3 running at once (owner rule).
- **xml 6.6 names:** if a member this plan uses has a different name in `package:xml` 6.6.1, use the 6.6.1 name with the same meaning, and say so in the report. Don't change behaviour.

## Review Focus

These are the five inputs most likely to bite a user, though no single feature test covers them. Each one has a test in the task named.

1. **A project created before Flutter 3.29** (Groovy `build.gradle`), or half converted (`settings.gradle.kts` with `app/build.gradle`, or both forms of one file). `sync` still exits 0; the Gradle values say why they're unknown; the manifests, the wrapper and `gradle.properties` are still read. *Tests: Task 5.*
2. **Values that aren't plain**: `maxOf(flutter.minSdkVersion, 26)`, a `"$template"` string, a key set twice, set inside `if`, inside `afterEvaluate { }`, the old `minSdkVersion(21)` form, a flavor with a computed name. Each is `unknown` with the reason, never a guessed value. *Tests: Task 3 (reader), Task 5 (values).*
3. **Missing or damaged files**: no `ios/` folder, broken XML, a binary `Info.plist`, a JSON-format `project.pbxproj`, a file that isn't UTF-8, a BOM, CRLF line endings. Only that file's values are affected, with the reason and the line; `sync` never fails. *Tests: Tasks 2, 4, 5, 6, 7.*
4. **The map is skipped** (`flutter pub get` fails). `native.json` is still written, and the generated `Package.swift` is `absent` with "`flutter pub get` writes it". *Tests: Task 7 (absent), Task 8 (sync).*
5. **SwiftPM set outside the project**: `FLUTTER_SWIFT_PACKAGE_MANAGER=1` (off, as in Flutter), an empty value (off), a global setting, an invalid global file (not set), a non-boolean pubspec value (unknown). Changing the variable or the global setting rewrites `native.json`. *Tests: Task 7 (decision), Task 8 (rewrite).*

## Decisions made while planning (for the owner's review)

Every fact below was checked against Flutter 3.47.5's own files on 2026-10-02.

- **D1, `native.json` is a small generic tree, not one class per field.**
  - **Shape:** a value is an object with a `status`; a group is an object of parts with fixed names; a list holds entries the project names.
  - **Why:** about 40 fields would each need a class, a `toJson` and a `fromJson`, while slices 1c and 1d only need to look values up by path (`NativeConfig.lookup(['android', 'app', 'minSdk'])`).
  - **Cost if wrong:** readers use string paths; typed accessors can be added in 1c or 1d.
- **D2, the names a project chooses are never JSON keys.** Flavors, permissions, usage descriptions and Xcode configurations are lists of entries with a `name`, sorted by name. So a flavor named `status` can't clash with the key that marks a value.
- **D3, `flutter.*` values are resolved the way Flutter's Gradle plugin resolves them:**
  - `flutter.compileSdkVersion`, `flutter.minSdkVersion`, `flutter.targetSdkVersion` and `flutter.ndkVersion` come from `toolchain.json`'s Android template, which is read from the SDK's `gradle_utils.dart` (or the curated notes, `resolvedFrom: notes`). In 3.47.5 those equal `FlutterExtension.kt`'s values: 36, 24, 36, `28.2.13676358`.
  - `flutter.versionCode` and `flutter.versionName` come from `pubspec.yaml`'s `version:`, by Flutter's rules:
    - `FlutterManifest.buildName`/`buildNumber`: the parts before and after `+`;
    - `validatedBuildNumberForPlatform` for Android: digits only, at least 1;
    - `pub_semver` parsing: an invalid version counts as none;
    - `FlutterPlugin.kt`'s defaults, `"1"` and `"1.0"`, when there is no build number or no valid version.
- **D4, the SwiftPM default:** on for Flutter ≥ 3.44.0 on every channel (all three channel settings are `enabledByDefault: true` in 3.47.5; the stable line changed in 3.44.0). For an older stable it's off. For an older beta or master it's `unknown`, because only the stable lines of 3.38 and 3.41 were checked.
- **D5, no platform pack, no `native.json`.** `packs.platforms` can't be empty in `appstein.yaml` (the config loader requires one), so this only happens in tests that pass packs by hand. The existing `KnowledgeSync` tests keep their expectations.
- **D6, `MapFiles.native` is added, and `MapFiles.all` stays the five files built from the Dart analysis.** Its doc comment says so.
- **D7, "set more than once" is `unknown` for Gradle scripts, but a `.properties` key set twice keeps its last value,** because Java's `Properties.load`, which Gradle uses, keeps the last one. That's a fact, not a guess.
- **D8, `swiftPackageIntegrated` is true exactly when `project.pbxproj`'s text contains `FlutterGeneratedPluginSwiftPackage`.** That is Flutter's own test (`flutterPluginSwiftPackageInProjectSettings` in `xcode_project.dart`).
- **D9, Xcode settings:** a key is read from the Runner target's configuration. If it isn't there, it comes from the project's configuration of the same name, with the note `set at project level`. If it's in neither, it's `unknown`: "may come from an .xcconfig file". A value containing `$(` is kept as written, with the note `uses Xcode build variables`.
- **D10, the generated `Package.swift`'s plugins** are the `.package(name: "…")` names other than `FlutterFramework` (Flutter's own dependency, `kFlutterGeneratedFrameworkSwiftPackageTargetName`), sorted. Paths are never read: they are absolute machine paths.
- **D11, the SwiftPM environment variable is read raw.** `HostEnvironment.variable` treats an empty value as unset, but Flutter (`_isEnabledByPlatformEnvironment`) treats it as set and false. The `ios` pack reads `HostEnvironment.variables` itself, with Windows' case-insensitive names.
- **D12, a failing pack costs only its section.** `NativeSync` catches anything from an extractor (`on Object`, as the delta does) and writes `{"status": "error", "errorType": "<type>"}` for that section. The full error goes to the CLI only.
- **D13, two packs claiming one section is a `StateError`,** a mistake in Appstein's pack list. The same check is added to `MapSync` for two extractors writing one map file (carried from slice 1b.3). `appstein.yaml` can't cause it: the config loader already rejects a platform listed twice (`config_loader.dart`, "appears twice").
- **D14, a `Podfile.lock` is hashed, not read.** Only whether it exists is recorded.

---

## File map

| File | Responsibility |
|---|---|
| `packages/appstein_protocol/lib/src/map/native_config.dart` | `NativeStatus`, `NativeNode`, `NativeValue`, `NativeGroup`, `NativeEntry`, `NativeList`, `NativeConfig` |
| `packages/appstein_protocol/lib/src/map/map_files.dart` | + `MapFiles.native` |
| `packages/appstein_engine/lib/src/native/native_extractor.dart` | `NativeContext`, `NativeSection`, `NativeExtractor` |
| `packages/appstein_engine/lib/src/native/native_files.dart` | `NativeFile`, `readNativeFile`, `lineAt`, `loadPubspec`, `yamlLine` |
| `packages/appstein_engine/lib/src/native/native_sync.dart` | `NativeReport`, `NativeBuild`, `NativeSync` |
| `packages/appstein_engine/lib/src/packs/pack.dart` | + `Pack.nativeExtractor` |
| `packages/appstein_engine/lib/src/map/map_sync.dart` | duplicate map-file paths are a `StateError` |
| `packages/appstein_engine/lib/src/packs/android/kts_reader.dart` | `readKts` and its model |
| `packages/appstein_engine/lib/src/packs/android/properties_reader.dart` | `readProperties` |
| `packages/appstein_engine/lib/src/packs/android/manifest_reader.dart` | `readManifest` |
| `packages/appstein_engine/lib/src/packs/android/android_native.dart` | `readAndroidNative`: the `android` section |
| `packages/appstein_engine/lib/src/packs/android/android_pack.dart` | `AndroidPack`, `AndroidNativeExtractor` |
| `packages/appstein_engine/lib/android.dart` | the `android` pack's library, for the CLI |
| `packages/appstein_engine/lib/src/packs/ios/plist_value.dart` | the property-list model both iOS readers share |
| `packages/appstein_engine/lib/src/packs/ios/info_plist_reader.dart` | `readXmlPlist` |
| `packages/appstein_engine/lib/src/packs/ios/pbxproj_reader.dart` | `readPbxproj` |
| `packages/appstein_engine/lib/src/packs/ios/ios_files.dart` | `readGeneratedPackage`, `readPodfile` |
| `packages/appstein_engine/lib/src/packs/ios/swiftpm_setting.dart` | `swiftPackageManagerEnabled`, `rawVariable` |
| `packages/appstein_engine/lib/src/packs/ios/ios_native.dart` | `readIosNative`: the `ios` section |
| `packages/appstein_engine/lib/src/packs/ios/ios_pack.dart` | `IosPack`, `IosNativeExtractor` |
| `packages/appstein_engine/lib/ios.dart` | the `ios` pack's library, for the CLI |
| `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` | `PlatformBuild.toolchain`; `SyncReport.native` |
| `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` | runs `NativeSync` after `MapSync` |
| `packages/appstein_cli/lib/src/packs.dart` | platform packs from `packs.platforms` |
| `packages/appstein_cli/lib/src/sync_command.dart` | prints the native line and errors |
| `tool/measure_sync.dart` | measures with the platform packs |
| `analysis_options.yaml` | `lib/android.dart` and `lib/ios.dart` get the pack tags |
| `packages/appstein_engine/test/fixtures/native/template_app/**.fixture` | The native files of a real 3.47.5 `flutter create` |
| `packages/appstein_engine/test/fixtures/apps/goldens/native.json.golden` | The template's `native.json` |
| `packages/appstein_engine/test/support/native_support.dart` | `nativeContext`, `flutterAndroidValues`, `copyNativeTemplate`, `writeProjectFiles` |
| `docs/guide/native-config.md` | New guide page |

---

### Task 1: The `native.json` model in the protocol

**Files:**
- Create: `packages/appstein_protocol/lib/src/map/native_config.dart`
- Modify: `packages/appstein_protocol/lib/src/map/map_files.dart`, `packages/appstein_protocol/lib/appstein_protocol.dart`
- Test: `packages/appstein_protocol/test/native_config_test.dart`

**Interfaces:**
- Consumes: `JsonFields` (`packages/appstein_protocol/lib/src/json_fields.dart`).
- Produces:
  - `enum NativeStatus { found, unknown, absent, error }`;
  - `sealed class NativeNode` with `static NativeNode fromJson(Object? json)` and `Object toJson()`;
  - `NativeValue.found(Object value, {String? at, String? expression, String? resolvedFrom, String? note})`, `NativeValue.unknown(String reason, {String? at})`, `NativeValue.absent(String reason, {String? at})`, `NativeValue.error(String errorType)`, with fields `status`, `value`, `at`, `expression`, `resolvedFrom`, `note`, `reason`, `errorType`;
  - `NativeGroup(Map<String, NativeNode> children)`;
  - `NativeEntry(String name, Map<String, NativeNode> children, {String? at})`;
  - `NativeList(List<NativeEntry> entries)` (sorted by name);
  - `NativeConfig(Map<String, NativeNode> sections)`, `NativeConfig.fromJson`, `NativeNode? lookup(List<String> path)`, `toJson()`;
  - `MapFiles.native == 'map/native.json'`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_protocol/test/native_config_test.dart`:

```dart
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
        'plugins': const NativeValue.found(
          ['com.android.application', 'dev.flutter.flutter-gradle-plugin'],
          at: 'android/app/build.gradle.kts:2',
        ),
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
        config.lookup(['android', 'app', 'flavors', 'dev', 'applicationIdSuffix'])!
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
      {'status': 'found', 'value': <Object?>[1]},
      {'status': 'unknown'},
      [1],
      [<String, Object?>{}],
      'text',
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

  test('native.json is a map file but not one built from the analysis', () {
    expect(MapFiles.native, 'map/native.json');
    expect(MapFiles.all, isNot(contains(MapFiles.native)));
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_protocol && fvm dart test test/native_config_test.dart`
Expected: FAIL to compile: `NativeConfig` isn't defined.

- [ ] **Step 3: Write the model**

Create `packages/appstein_protocol/lib/src/map/native_config.dart`:

```dart
import '../json_fields.dart';

const _file = 'native.json';

/// What Appstein knows about one native value (spec §6.5).
enum NativeStatus {
  /// Read from a file, with where it is.
  found,

  /// Present, but not a plain value Appstein can read: computed in Gradle
  /// code, set more than once, set conditionally, or in a file that can't
  /// be read. Never guessed.
  unknown,

  /// Not set, or its file doesn't exist.
  absent,

  /// The platform pack failed (an Appstein bug). Only a whole section has
  /// this status.
  error,
}

/// A part of `map/native.json` (spec §6.5): a [NativeValue], a
/// [NativeGroup] of parts with names Appstein chose, or a [NativeList] of
/// entries the project names (flavors, permissions, Xcode configurations).
sealed class NativeNode {
  /// Lets subclasses be constant.
  const NativeNode();

  /// Reads a node from its JSON form: a list is a [NativeList], an object
  /// with a `status` key a [NativeValue], and any other object a
  /// [NativeGroup].
  ///
  /// Throws a [FormatException] when it is none of these.
  static NativeNode fromJson(Object? json) => switch (json) {
    final List<Object?> list => NativeList._read(list),
    final Map<String, Object?> map when map.containsKey('status') =>
      NativeValue._read(map),
    final Map<String, Object?> map => NativeGroup._read(map),
    _ => throw const FormatException(
      '$_file: a part must be an object or a list.',
    ),
  };

  /// The JSON form.
  Object toJson();
}

/// One native value and what Appstein knows about it.
final class NativeValue extends NativeNode {
  /// A value read from a file.
  ///
  /// [value] is a string, an integer, a boolean or a list of strings. [at]
  /// is where it is: `path` or `path:line`, relative to the project, with
  /// `/`. [expression] is how the file wrote it when that isn't the value
  /// itself, such as `flutter.minSdkVersion`. [resolvedFrom] says where the
  /// value of an expression or a setting came from, such as `flutter`,
  /// `notes`, `pubspec.yaml:19` or `default`. [note] is anything else a
  /// reader must know, such as `set at project level`.
  const NativeValue.found(
    Object this.value, {
    this.at,
    this.expression,
    this.resolvedFrom,
    this.note,
  }) : status = NativeStatus.found,
       reason = null,
       errorType = null;

  /// A value Appstein can't read plainly, and why.
  const NativeValue.unknown(String this.reason, {this.at})
    : status = NativeStatus.unknown,
      value = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      errorType = null;

  /// A value that isn't set, or whose file doesn't exist, and why.
  const NativeValue.absent(String this.reason, {this.at})
    : status = NativeStatus.absent,
      value = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      errorType = null;

  /// A section whose platform pack failed with an error of [errorType] (an
  /// Appstein bug). Only the type is kept: the message may hold a machine
  /// path.
  const NativeValue.error(String this.errorType)
    : status = NativeStatus.error,
      value = null,
      at = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      reason = null;

  factory NativeValue._read(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    final at = fields.optionalString('at');
    return switch (NativeStatus.values.asNameMap()[fields.string('status')]) {
      NativeStatus.found => NativeValue.found(
        _readValue(json['value']),
        at: at,
        expression: fields.optionalString('expression'),
        resolvedFrom: fields.optionalString('resolvedFrom'),
        note: fields.optionalString('note'),
      ),
      NativeStatus.unknown => NativeValue.unknown(
        fields.string('reason'),
        at: at,
      ),
      NativeStatus.absent => NativeValue.absent(
        fields.string('reason'),
        at: at,
      ),
      NativeStatus.error => NativeValue.error(fields.string('errorType')),
      null => throw const FormatException(
        '$_file: "status" must be found, unknown, absent or error.',
      ),
    };
  }

  static Object _readValue(Object? value) => switch (value) {
    final String text => text,
    final int number => number,
    final bool flag => flag,
    final List<Object?> list when list.every((item) => item is String) =>
      List<String>.unmodifiable(list.cast<String>()),
    _ => throw const FormatException(
      '$_file: "value" must be a string, an integer, true or false, or a '
      'list of strings.',
    ),
  };

  /// What Appstein knows.
  final NativeStatus status;

  /// The value, when [status] is [NativeStatus.found]: a string, an
  /// integer, a boolean or a list of strings.
  final Object? value;

  /// Where it is: `path` or `path:line`, relative to the project.
  final String? at;

  /// How the file wrote it, when that isn't the value itself.
  final String? expression;

  /// Where the value of an expression or a setting came from.
  final String? resolvedFrom;

  /// Anything else a reader must know.
  final String? note;

  /// Why it is unknown or absent.
  final String? reason;

  /// The type of the error that stopped the pack, for an `error` section.
  final String? errorType;

  @override
  Map<String, Object?> toJson() => {
    'status': status.name,
    if (value != null) 'value': value,
    if (at != null) 'at': at,
    if (expression != null) 'expression': expression,
    if (resolvedFrom != null) 'resolvedFrom': resolvedFrom,
    if (note != null) 'note': note,
    if (reason != null) 'reason': reason,
    if (errorType != null) 'errorType': errorType,
  };
}

/// Parts with names Appstein chose, such as `app` or `minSdk`.
final class NativeGroup extends NativeNode {
  /// Creates the group. No part may be named `status`, the key that marks
  /// a value.
  NativeGroup(Map<String, NativeNode> children)
    : children = Map.unmodifiable(children) {
    if (children.containsKey('status')) {
      throw ArgumentError.value(
        'status',
        'children',
        'is the key that marks a value',
      );
    }
  }

  factory NativeGroup._read(Map<String, Object?> json) => NativeGroup({
    for (final MapEntry(:key, :value) in json.entries)
      key: NativeNode.fromJson(value),
  });

  /// The parts, by name.
  final Map<String, NativeNode> children;

  @override
  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in children.entries)
      key: value.toJson(),
  };
}

/// One entry of a [NativeList]: something the project names, where it is,
/// and its parts.
final class NativeEntry {
  /// Creates the entry. No part may be named `name`, `at` or `status`,
  /// which its JSON form uses.
  NativeEntry(this.name, Map<String, NativeNode> children, {this.at})
    : children = Map.unmodifiable(children) {
    for (final key in const ['name', 'at', 'status']) {
      if (children.containsKey(key)) {
        throw ArgumentError.value(key, 'children', 'is used by the entry');
      }
    }
  }

  factory NativeEntry._read(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('$_file: a list entry must be an object.');
    }
    final fields = JsonFields(_file, json);
    return NativeEntry(
      fields.string('name'),
      {
        for (final MapEntry(:key, :value) in json.entries)
          if (key != 'name' && key != 'at') key: NativeNode.fromJson(value),
      },
      at: fields.optionalString('at'),
    );
  }

  /// The name the project gave it, such as a flavor's.
  final String name;

  /// Where it is declared: `path:line`.
  final String? at;

  /// Its parts, by name.
  final Map<String, NativeNode> children;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'name': name,
    if (at != null) 'at': at,
    for (final MapEntry(:key, :value) in children.entries)
      key: value.toJson(),
  };
}

/// Entries the project names, sorted by name. The names are never JSON
/// keys, so no name can clash with a key Appstein uses.
final class NativeList extends NativeNode {
  /// Creates the list, sorted by name.
  NativeList(List<NativeEntry> entries)
    : entries = List.unmodifiable(
        [...entries]..sort((a, b) => a.name.compareTo(b.name)),
      );

  factory NativeList._read(List<Object?> json) =>
      NativeList([for (final item in json) NativeEntry._read(item)]);

  /// The entries, sorted by name.
  final List<NativeEntry> entries;

  @override
  List<Map<String, Object?>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];
}

/// The contents of `map/native.json` (spec §6.5): one section per platform
/// pack, such as `android` and `ios`.
final class NativeConfig {
  /// Creates the file's contents.
  NativeConfig(Map<String, NativeNode> sections)
    : sections = Map.unmodifiable(sections);

  /// Reads the file's JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a malformed part.
  factory NativeConfig.fromJson(Map<String, Object?> json) => NativeConfig({
    for (final MapEntry(:key, :value) in json.entries)
      if (key != 'meta') key: NativeNode.fromJson(value),
  });

  /// The sections, by pack: `android`, `ios`.
  final Map<String, NativeNode> sections;

  /// The part at [path], such as `['android', 'app', 'minSdk']`: a section,
  /// then parts of groups, or entries of lists by name. An entry comes back
  /// as a [NativeGroup] of its parts. Null when there is none.
  NativeNode? lookup(List<String> path) {
    if (path.isEmpty) return null;
    var node = sections[path.first];
    for (final name in path.skip(1)) {
      node = switch (node) {
        NativeGroup(:final children) => children[name],
        NativeList(:final entries) => switch (entries
            .where((entry) => entry.name == name)
            .firstOrNull) {
          final entry? => NativeGroup(entry.children),
          null => null,
        },
        _ => null,
      };
    }
    return node;
  }

  /// The JSON form, without `meta` (the store adds it).
  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in sections.entries)
      key: value.toJson(),
  };
}
```

In `packages/appstein_protocol/lib/src/map/map_files.dart`, add after `routes`:

```dart
  /// The Android and iOS setup (written by the platform packs). It is built
  /// without the Dart analysis, so it is written even when the rest of the
  /// map is skipped.
  static const native = 'map/native.json';
```

and change the doc comment of `all` to:

```dart
  /// The five files built from the Dart analysis, sorted. [native] isn't
  /// one of them.
```

In `packages/appstein_protocol/lib/appstein_protocol.dart`, add `export 'src/map/native_config.dart';` after the `map_files.dart` export.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: PASS, the existing tests included.

- [ ] **Step 5: Commit (controller)**

```bash
git add packages/appstein_protocol
git commit -m "feat(protocol): the native.json model (spec §6.5)"
```

---

### Task 2: Native extractors and `NativeSync` in the engine core

**Files:**
- Create: `packages/appstein_engine/lib/src/native/native_extractor.dart`, `packages/appstein_engine/lib/src/native/native_files.dart`, `packages/appstein_engine/lib/src/native/native_sync.dart`
- Modify: `packages/appstein_engine/lib/src/packs/pack.dart`, `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart`, `packages/appstein_engine/lib/src/map/map_sync.dart`, `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/native/native_files_test.dart`, `packages/appstein_engine/test/native/native_sync_test.dart`, `packages/appstein_engine/test/map/map_sync_test.dart`

**Interfaces:**
- Consumes: Task 1's model; `GeneratedFile`, `inputHash`, `knowledgeFormatVersion`, `HostEnvironment`, `fileErrorReason`, `Sourced<AndroidToolchain>`.
- Produces:
  - `NativeContext({required String projectRoot, required String flutterVersion, required String channel, required HostEnvironment environment, Sourced<AndroidToolchain>? android})`;
  - `NativeSection(NativeNode node, Map<String, List<int>?> inputs)`;
  - `abstract interface class NativeExtractor { String get section; NativeSection extract(NativeContext context); }`;
  - `NativeFile` with `path`, `bytes`, `text`, `error`, `exists`, `at(int line)`, `input`; `NativeFile readNativeFile(String projectRoot, String path)`; `int lineAt(String text, int offset)`; `YamlMap? loadPubspec(NativeFile pubspec)`; `int yamlLine(YamlNode node)`;
  - `NativeReport({Map<String, String> sections, Map<String, String> errors})`, `NativeBuild({GeneratedFile? file, NativeReport report})`, `NativeSync({required String appsteinVersion, required List<Pack> packs})` with `NativeBuild build(NativeContext context)`;
  - `Pack.nativeExtractor` (`NativeExtractor?`).

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/native/native_files_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  void write(String path, List<int> bytes) => File(p.joinAll([root, ...path.split('/')]))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  test('a missing file has no bytes, text or error, and hashes as missing', () {
    final file = readNativeFile(root, 'ios/Podfile');
    expect(file.exists, isFalse);
    expect(file.text, isNull);
    expect(file.error, isNull);
    expect(file.input, isA<MapEntry<String, List<int>?>>());
    expect(file.input.key, 'file:ios/Podfile');
    expect(file.input.value, isNull);
  });

  test('a byte order mark is dropped from the text but kept in the bytes',
      () {
    write('android/gradle.properties', [0xEF, 0xBB, 0xBF, ...utf8.encode('a=1\n')]);
    final file = readNativeFile(root, 'android/gradle.properties');
    expect(file.text, 'a=1\n');
    expect(file.bytes!.length, 7);
    expect(file.at(3), 'android/gradle.properties:3');
  });

  test('a file that is not UTF-8 exists, has bytes, and says why there is no '
      'text', () {
    write('ios/Runner/Info.plist', [0xFF, 0xFE, 0x00]);
    final file = readNativeFile(root, 'ios/Runner/Info.plist');
    expect(file.exists, isTrue);
    expect(file.text, isNull);
    expect(file.error, 'not valid UTF-8');
  });

  test('a folder where a file should be counts as missing', () {
    Directory(p.join(root, 'ios', 'Podfile')).createSync(recursive: true);
    expect(readNativeFile(root, 'ios/Podfile').exists, isFalse);
  });

  test('lineAt counts lines from 1, with CRLF or LF', () {
    const text = 'a\r\nb\nc';
    expect(lineAt(text, 0), 1);
    expect(lineAt(text, text.indexOf('b')), 2);
    expect(lineAt(text, text.indexOf('c')), 3);
  });

  test('loadPubspec gives the map with lines, or null when it is broken', () {
    write('pubspec.yaml', utf8.encode('name: app\nversion: 1.2.3+4\n'));
    final pubspec = loadPubspec(readNativeFile(root, 'pubspec.yaml'))!;
    expect(yamlLine(pubspec.nodes['version']!), 2);
    write('pubspec.yaml', utf8.encode('name: [\n'));
    expect(loadPubspec(readNativeFile(root, 'pubspec.yaml')), isNull);
    write('pubspec.yaml', utf8.encode('- a list\n'));
    expect(loadPubspec(readNativeFile(root, 'pubspec.yaml')), isNull);
  });
}
```

Create `packages/appstein_engine/test/native/native_sync_test.dart`:

```dart
import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/temp.dart';

final class _Extractor implements NativeExtractor {
  _Extractor(this.section, this.result);

  @override
  final String section;

  final NativeSection Function(NativeContext context) result;

  @override
  NativeSection extract(NativeContext context) => result(context);
}

final class _Pack implements Pack {
  _Pack(this.id, this.nativeExtractor);

  @override
  final String id;

  @override
  final NativeExtractor? nativeExtractor;

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;
}

void main() {
  NativeContext context({String flutter = '3.47.5'}) => NativeContext(
    projectRoot: tempDir().path,
    flutterVersion: flutter,
    channel: 'stable',
    environment: fakeEnvironment({}),
  );

  Pack pack(String section, NativeSection Function(NativeContext) result) =>
      _Pack(section, _Extractor(section, result));

  NativeSync sync(List<Pack> packs) =>
      NativeSync(appsteinVersion: '0.1.0-dev', packs: packs);

  test('with no native extractor there is no file', () {
    final build = sync([
      _Pack('official_mvvm', null),
    ]).build(context());
    expect(build.file, isNull);
    expect(build.report.sections, isEmpty);
  });

  test('each pack writes its own section of map/native.json', () {
    final build = sync([
      pack(
        'android',
        (_) => NativeSection(
          NativeGroup({'gradle': const NativeValue.found('9.3.1')}),
          {'file:android/gradle.properties': utf8.encode('a=1')},
        ),
      ),
      pack(
        'ios',
        (_) => const NativeSection(NativeValue.absent('no ios/ folder'), {}),
      ),
    ]).build(context());
    expect(build.file!.path, MapFiles.native);
    expect(build.file!.body, {
      'android': {
        'gradle': {'status': 'found', 'value': '9.3.1'},
      },
      'ios': {'status': 'absent', 'reason': 'no ios/ folder'},
    });
    expect(build.report.sections, {
      'android': 'read',
      'ios': 'absent: no ios/ folder',
    });
    expect(build.report.errors, isEmpty);
  });

  test('a pack that throws costs only its own section', () {
    final build = sync([
      pack('android', (_) => throw StateError('broken at C:\\Users\\me')),
      pack(
        'ios',
        (_) => const NativeSection(NativeValue.absent('no ios/ folder'), {}),
      ),
    ]).build(context());
    expect(build.file!.body!['android'], {
      'status': 'error',
      'errorType': 'StateError',
    });
    expect(build.file!.body!['ios'], isNotNull);
    expect(build.report.sections['android'], 'internal error (StateError)');
    expect(build.report.errors['android'], contains('broken at'));
    expect(jsonEncode(build.file!.body), isNot(contains('Users')));
  });

  test('two packs writing one section is a StateError', () {
    NativeSection empty(NativeContext _) =>
        const NativeSection(NativeValue.absent('x'), {});
    expect(
      () => sync([pack('android', empty), pack('android', empty)])
          .build(context()),
      throwsStateError,
    );
  });

  test('the hash follows the inputs and the Flutter version', () {
    String hash(List<int>? bytes, {String flutter = '3.47.5'}) => sync([
      pack(
        'android',
        (_) => NativeSection(const NativeValue.found(1), {'file:x': bytes}),
      ),
    ]).build(context(flutter: flutter)).file!.inputHash;

    expect(hash([1]), hash([1]));
    expect(hash([1]), isNot(hash([2])));
    expect(hash([1]), isNot(hash(null)));
    expect(hash([1]), isNot(hash([1], flutter: '3.44.9')));
  });
}
```

Create `packages/appstein_engine/test/map/map_sync_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/temp.dart';

final class _RoutesAgain implements MapExtractor {
  const _RoutesAgain();

  @override
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis) => {
    MapFiles.routes: const {'routes': <Object?>[]},
  };
}

final class _SecondPack implements Pack {
  const _SecondPack();

  @override
  String get id => 'second';

  @override
  PackKind get kind => PackKind.stack;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [_RoutesAgain()];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor? get nativeExtractor => null;
}

void main() {
  test('two extractors writing the same map file is a StateError', () async {
    final app = copyFixtureApp();
    final sync = MapSync(
      environment: fakeEnvironment({}),
      appsteinVersion: '0.1.0-dev',
      packs: const [OfficialMvvmPack(), _SecondPack()],
      runner: FakeProcessRunner(),
    );
    await expectLater(
      sync.build(
        app,
        flutterVersion: '3.47.5',
        flutterRoot: tempDir().path,
        dartSdkPath: testDartSdk,
      ),
      throwsStateError,
    );
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/native test/map/map_sync_test.dart`
Expected: FAIL to compile: `NativeContext`, `readNativeFile` and `Pack.nativeExtractor` don't exist.

- [ ] **Step 3: Write the seam**

Create `packages/appstein_engine/lib/src/native/native_extractor.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../host/host_environment.dart';

/// What a native extractor may use (spec §6.5). There is no Dart analysis
/// here on purpose: `native.json` is built even when the map is skipped.
final class NativeContext {
  /// Creates the context.
  const NativeContext({
    required this.projectRoot,
    required this.flutterVersion,
    required this.channel,
    required this.environment,
    this.android,
  });

  /// The project's root folder.
  final String projectRoot;

  /// The Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The Flutter channel, such as `stable`.
  final String channel;

  /// The machine: environment variables and the OS, for settings Flutter
  /// reads from outside the project.
  final HostEnvironment environment;

  /// Flutter's Android values for this SDK (what `flutter.minSdkVersion`
  /// and the others resolve to), as `toolchain.json` read them; null when
  /// neither the SDK nor the curated notes give them.
  final Sourced<AndroidToolchain>? android;
}

/// One section of `native.json` and everything it was built from.
final class NativeSection {
  /// Pairs the section's [node] with its [inputs].
  const NativeSection(this.node, this.inputs);

  /// The section: a group of values, or one value when the whole section
  /// is absent (such as no `ios/` folder).
  final NativeNode node;

  /// Every input it read, by a stable name (`file:android/gradle.properties`,
  /// `env:FLUTTER_SWIFT_PACKAGE_MANAGER`), to its bytes or null when
  /// missing. They go into the file's input hash.
  final Map<String, List<int>?> inputs;
}

/// Builds one section of `map/native.json` from a project's native files
/// (spec §6.5, §10). Platform packs provide one.
abstract interface class NativeExtractor {
  /// The section it writes, such as `android`.
  String get section;

  /// Reads the project's native files. It never throws for the project's
  /// own problems: a missing or damaged file becomes `absent` or `unknown`
  /// values.
  NativeSection extract(NativeContext context);
}
```

Create `packages/appstein_engine/lib/src/native/native_files.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../host/file_errors.dart';

/// A project file a native extractor read (spec §6.5).
final class NativeFile {
  const NativeFile._(this.path, {this.bytes, this.text, this.error});

  /// Its path relative to the project, with `/`, such as
  /// `android/app/build.gradle.kts`.
  final String path;

  /// Its bytes; null when it is missing or unreadable.
  final List<int>? bytes;

  /// Its text, without a leading byte order mark; null when it is missing,
  /// unreadable or not UTF-8.
  final String? text;

  /// Why there is no [text] although the file exists; null otherwise.
  final String? error;

  /// Whether the file exists.
  bool get exists => bytes != null || error != null;

  /// [path] with a 1-based [line]: `path:line`.
  String at(int line) => '$path:$line';

  /// This file's entry in an input hash: its bytes, a marker when it can't
  /// be read, or null when it is missing.
  MapEntry<String, List<int>?> get input => MapEntry(
    'file:$path',
    bytes ?? (error == null ? null : utf8.encode('unreadable: $error')),
  );
}

/// Reads [path] (relative, with `/`) in the project at [projectRoot]. It
/// never throws: a missing file, or one that can't be read or isn't UTF-8,
/// is described by the [NativeFile].
NativeFile readNativeFile(String projectRoot, String path) {
  final file = File(p.joinAll([projectRoot, ...path.split('/')]));
  if (!file.existsSync()) return NativeFile._(path);
  final List<int> bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException catch (error) {
    return NativeFile._(path, error: fileErrorReason(error));
  }
  try {
    var text = utf8.decode(bytes);
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    return NativeFile._(path, bytes: bytes, text: text);
  } on FormatException {
    return NativeFile._(path, bytes: bytes, error: 'not valid UTF-8');
  }
}

/// The 1-based line of [offset] in [text]. A `\r\n` counts as one line end.
int lineAt(String text, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// The project's `pubspec.yaml` as a map that keeps line numbers, or null
/// when it is missing, can't be read, or isn't a YAML map.
YamlMap? loadPubspec(NativeFile pubspec) {
  final text = pubspec.text;
  if (text == null) return null;
  try {
    final node = loadYamlNode(text);
    return node is YamlMap ? node : null;
  } on YamlException {
    return null;
  }
}

/// The 1-based line where [node] starts.
int yamlLine(YamlNode node) => node.span.start.line + 1;
```

Create `packages/appstein_engine/lib/src/native/native_sync.dart`:

```dart
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../knowledge/generated_file.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'native_extractor.dart';

/// What the native part of a sync did.
final class NativeReport {
  /// Creates the report.
  const NativeReport({this.sections = const {}, this.errors = const {}});

  /// Each section's outcome in a few words, by section: `read`,
  /// `absent: <why>` (such as `absent: no ios/ folder`), or
  /// `internal error (<type>)`.
  final Map<String, String> sections;

  /// The full error of each section whose pack failed (an Appstein bug),
  /// for the person running the sync. It may hold a machine path, so it
  /// never goes into a generated file.
  final Map<String, String> errors;
}

/// `map/native.json`, built but not yet written.
final class NativeBuild {
  /// Creates the build.
  const NativeBuild({this.file, this.report = const NativeReport()});

  /// The file, or null when no pack has a native extractor.
  final GeneratedFile? file;

  /// What happened.
  final NativeReport report;
}

/// Builds `map/native.json` (spec §6.5) from the platform packs' native
/// extractors. It needs no Dart analysis, so `KnowledgeSync` runs it even
/// when the rest of the map is skipped.
final class NativeSync {
  /// Creates the sync for [packs]; only their native extractors run.
  const NativeSync({required this.appsteinVersion, required this.packs});

  /// The version of the running Appstein; part of the input hash.
  final String appsteinVersion;

  /// The project's packs.
  final List<Pack> packs;

  /// Builds the file.
  ///
  /// A pack that throws costs only its own section: it becomes an `error`
  /// value with the error's type, and the error is in
  /// [NativeReport.errors]. Throws a [StateError] when two packs write the
  /// same section, a mistake in Appstein's pack list.
  NativeBuild build(NativeContext context) {
    final extractors = [
      for (final pack in packs)
        if (pack.nativeExtractor case final extractor?) (pack, extractor),
    ];
    if (extractors.isEmpty) return const NativeBuild();
    final seen = <String>{};
    for (final (_, extractor) in extractors) {
      if (!seen.add(extractor.section)) {
        throw StateError(
          'Two packs write the "${extractor.section}" section of '
          '${MapFiles.native}.',
        );
      }
    }

    final sections = <String, NativeNode>{};
    final inputs = <String, List<int>?>{};
    final outcomes = <String, String>{};
    final errors = <String, String>{};
    for (final (_, extractor) in extractors) {
      final name = extractor.section;
      try {
        final section = extractor.extract(context);
        sections[name] = section.node;
        for (final MapEntry(:key, :value) in section.inputs.entries) {
          inputs['$name:$key'] = value;
        }
        outcomes[name] = switch (section.node) {
          NativeValue(status: NativeStatus.absent, :final reason) =>
            'absent: $reason',
          _ => 'read',
        };
        // Any failure is an Appstein bug and must not cost the other
        // sections or the sync. `on Object` is deliberate, as in MapSync.
      } on Object catch (error) {
        final type = '${error.runtimeType}';
        sections[name] = NativeValue.error(type);
        inputs['$name:error'] = utf8.encode(type);
        outcomes[name] = 'internal error ($type)';
        errors[name] = '$error';
      }
    }

    final hash = inputHash(
      {
        ...inputs,
        'flutter': utf8.encode(context.flutterVersion),
        'channel': utf8.encode(context.channel),
        'packs': utf8.encode(
          [for (final (pack, _) in extractors) '${pack.id}@${pack.version}']
              .join(','),
        ),
      },
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
    return NativeBuild(
      file: GeneratedFile(
        path: MapFiles.native,
        body: NativeConfig(sections).toJson(),
        inputHash: hash,
      ),
      report: NativeReport(sections: outcomes, errors: errors),
    );
  }
}
```

`knowledgeFormatVersion` is the protocol's constant that `MapSync` already uses.

- [ ] **Step 4: Add the pack member and the map-file check**

In `packages/appstein_engine/lib/src/packs/pack.dart`, add `import '../native/native_extractor.dart';` and, after `extractors`:

```dart
  /// What it adds to `map/native.json` (spec §6.5); null for a stack pack.
  /// Platform packs arrive in slice 1b.4.
  NativeExtractor? get nativeExtractor;
```

In `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart`, add `import '../../native/native_extractor.dart';` and, after `layerRules`:

```dart
  @override
  NativeExtractor? get nativeExtractor => null;
```

In `packages/appstein_engine/lib/src/map/map_sync.dart`, replace `bodies.addAll(extractor.extract(analysis));` with:

```dart
          for (final MapEntry(:key, :value)
              in extractor.extract(analysis).entries) {
            if (bodies.containsKey(key)) {
              throw StateError('Two packs write $key.');
            }
            bodies[key] = value;
          }
```

The `try` around this loop catches only `DependenciesException` and `FileSystemException`, so the `StateError` reaches the caller (the test expects it).

In `packages/appstein_engine/lib/appstein_engine.dart`, add, sorted with the others:

```dart
export 'src/native/native_extractor.dart';
export 'src/native/native_files.dart';
export 'src/native/native_sync.dart';
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/native test/map test/packs test/knowledge`
Expected: PASS. Then `fvm dart analyze --fatal-infos` from the repo root: clean.

- [ ] **Step 6: Commit (controller)**

```bash
git add packages/appstein_engine
git commit -m "feat(engine): native extractors and NativeSync; two packs writing one map file is an error"
```

---

### Task 3: The Gradle Kotlin script reader

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/android/kts_reader.dart`
- Test: `packages/appstein_engine/test/packs/android/kts_reader_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `const ktsOpaque = '?'`;
  - `sealed class KtsValue { String get text; }` with `KtsString(String value, String text)`, `KtsInt(int value, String text)`, `KtsBool(bool value, String text)`, `KtsName(String text)`, `KtsCallValue(String name, String argument, String text)`, `KtsComputed(String text)`;
  - `KtsAssignment({path, value, line})` with `conditional`, `plainPath`;
  - `KtsCall({path, name, arguments, argument, infix, line})` with `conditional`, `plainPath`;
  - `KtsBlock({path, line})`;
  - `KtsScript` with `assignments`, `calls`, `blocks`, `assignmentsTo(List<String> path)`, `callsTo(List<String> path, String name)`, `blocksIn(List<String> path)`;
  - `bool ktsPathIs(List<String> a, List<String> b)`;
  - `KtsFormatException(String message, int line)`;
  - `KtsScript readKts(String text)`.

This is not a Kotlin parser. It knows strings (with `$` templates), comments (nested `/* */` too), numbers and brackets. It follows `name { … }` blocks and records three things with the block path they're in: assignments (`a.b = value`), call statements (`id("x") version "1.0"`), and blocks. Anything it doesn't follow (`if`, `when`, loops, `try`, lambdas passed to other calls) still has its contents read, under a `?` segment, so a value set there is seen and reported as conditional rather than missed.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/packs/android/kts_reader_test.dart`:

```dart
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
    expect(
      only(script, ['android', 'defaultConfig', 'minSdk']).line,
      16,
    );
    expect(
      only(script, ['android', 'compileOptions', 'sourceCompatibility']).value
          .text,
      'JavaVersion.VERSION_17',
    );
    expect(
      only(script, ['kotlin', 'compilerOptions', 'jvmTarget']).value.text,
      'org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17',
    );
    final signing =
        only(script, ['android', 'buildTypes', 'release', 'signingConfig'])
                .value
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
      ktsPathIs(
        only(script, ['android', 'defaultConfig', 'targetSdk']).path,
        ['android', 'defaultConfig', 'targetSdk'],
      ),
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
      [for (final block in script.blocksIn(['android', 'productFlavors'])) block.path.last],
      ['dev', 'prod', ktsOpaque],
    );
    expect(
      only(script, ['android', 'productFlavors', 'dev', 'applicationIdSuffix'])
          .line,
      3,
    );
    expect(
      only(script, ['android', 'buildTypes', 'release', 'isMinifyEnabled'])
          .conditional,
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
        throwsA(
          isA<KtsFormatException>().having((e) => e.line, 'line', line),
        ),
        reason: text,
      );
    }
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android/kts_reader_test.dart`
Expected: FAIL to compile: the library doesn't exist.

- [ ] **Step 3: Write the reader**

Create `packages/appstein_engine/lib/src/packs/android/kts_reader.dart`:

```dart
/// Reads Gradle's Kotlin build scripts (`.gradle.kts`) far enough to find
/// plain settings (spec §6.5).
///
/// It is not a Kotlin parser. It knows strings (with `$` templates),
/// comments (nested `/* */` too), numbers and brackets; follows
/// `name { … }` blocks; and records each assignment, call statement and
/// block with the path of blocks it is in. The contents of anything it
/// doesn't follow (an `if`, `when`, loop or `try`, or a lambda passed to a
/// call) are read under a [ktsOpaque] segment, so a value set there is
/// seen and can be reported as conditional, never missed. A value that
/// isn't a plain literal or name is kept as [KtsComputed], never evaluated.
library;

/// The path segment of a block Appstein doesn't follow.
const ktsOpaque = '?';

/// The value on the right of `=`, as written.
sealed class KtsValue {
  const KtsValue(this.text);

  /// The value's text, with its spacing normalized.
  final String text;
}

/// A string literal without `$` templates, such as `"dev.sample.app"`.
final class KtsString extends KtsValue {
  /// Creates the value.
  const KtsString(this.value, super.text);

  /// The string, with its escapes decoded.
  final String value;
}

/// An integer literal, such as `36`.
final class KtsInt extends KtsValue {
  /// Creates the value.
  const KtsInt(this.value, super.text);

  /// The number.
  final int value;
}

/// `true` or `false`.
final class KtsBool extends KtsValue {
  /// Creates the value.
  const KtsBool(this.value, super.text);

  /// The boolean.
  final bool value;
}

/// A name, or names joined by dots, such as `flutter.minSdkVersion` or
/// `JavaVersion.VERSION_17`.
final class KtsName extends KtsValue {
  /// Creates the value.
  const KtsName(super.text);
}

/// A call with one string argument, such as
/// `signingConfigs.getByName("debug")`.
final class KtsCallValue extends KtsValue {
  /// Creates the value.
  const KtsCallValue(this.name, this.argument, super.text);

  /// The called name, such as `signingConfigs.getByName`.
  final String name;

  /// The argument, such as `debug`.
  final String argument;
}

/// Anything else: computed when Gradle runs. Never evaluated.
final class KtsComputed extends KtsValue {
  /// Creates the value.
  const KtsComputed(super.text);
}

/// `a.b = value` (or `+=`, `-=`).
final class KtsAssignment {
  /// Creates the assignment.
  const KtsAssignment({
    required this.path,
    required this.value,
    required this.line,
  });

  /// The blocks it is in, then the parts of the assigned name:
  /// `android { defaultConfig { minSdk = 24 } }` and
  /// `android.defaultConfig.minSdk = 24` both give
  /// `[android, defaultConfig, minSdk]`.
  final List<String> path;

  /// The assigned value.
  final KtsValue value;

  /// Its 1-based line.
  final int line;

  /// Whether it is inside a block Appstein doesn't follow.
  bool get conditional => path.contains(ktsOpaque);

  /// [path] without its [ktsOpaque] segments.
  List<String> get plainPath => [
    for (final segment in path)
      if (segment != ktsOpaque) segment,
  ];
}

/// A call statement, such as
/// `id("com.android.application") version "9.1.0" apply false` or
/// `minSdkVersion(21)`.
final class KtsCall {
  /// Creates the call.
  const KtsCall({
    required this.path,
    required this.name,
    required this.arguments,
    required this.argument,
    required this.infix,
    required this.line,
  });

  /// The blocks it is in, then the parts of its name before the last.
  final List<String> path;

  /// The last part of its name, such as `id`.
  final String name;

  /// The text between its parentheses.
  final String arguments;

  /// Its argument, when there is exactly one and it is a string without
  /// templates, a number, `true`/`false` or a name; else null.
  final KtsValue? argument;

  /// The words after the parentheses and their values, such as `version`
  /// to `"9.1.0"` and `apply` to `false`.
  final Map<String, KtsValue> infix;

  /// Its 1-based line.
  final int line;

  /// Whether it is inside a block Appstein doesn't follow.
  bool get conditional => path.contains(ktsOpaque);

  /// [path] without its [ktsOpaque] segments.
  List<String> get plainPath => [
    for (final segment in path)
      if (segment != ktsOpaque) segment,
  ];
}

/// A `name { … }` block, or a container entry such as
/// `create("dev") { … }`.
final class KtsBlock {
  /// Creates the block.
  const KtsBlock({required this.path, required this.line});

  /// The blocks it is in, then its own name: `dev` for `create("dev")`,
  /// or [ktsOpaque] when Appstein doesn't follow it.
  final List<String> path;

  /// The 1-based line it starts on.
  final int line;
}

/// Whether the paths [a] and [b] are the same.
bool ktsPathIs(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _endsWith(List<String> list, List<String> suffix) {
  if (list.length < suffix.length) return false;
  final offset = list.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (list[offset + i] != suffix[i]) return false;
  }
  return true;
}

/// What [readKts] found in a script.
final class KtsScript {
  /// Creates the result.
  const KtsScript({
    required this.assignments,
    required this.calls,
    required this.blocks,
  });

  /// Every assignment, in file order.
  final List<KtsAssignment> assignments;

  /// Every call statement, in file order.
  final List<KtsCall> calls;

  /// Every block, in file order.
  final List<KtsBlock> blocks;

  /// Every assignment to [path], such as
  /// `['android', 'defaultConfig', 'minSdk']`: the ones whose
  /// [KtsAssignment.plainPath] ends with it. A plain setting is exactly at
  /// [path] ([ktsPathIs]); the others are inside an `if`, a lambda, or a
  /// block such as `afterEvaluate { }`.
  List<KtsAssignment> assignmentsTo(List<String> path) => [
    for (final assignment in assignments)
      if (_endsWith(assignment.plainPath, path)) assignment,
  ];

  /// Every call named [name] in the blocks of [path], found the same way
  /// as [assignmentsTo].
  List<KtsCall> callsTo(List<String> path, String name) => [
    for (final call in calls)
      if (call.name == name && _endsWith(call.plainPath, path)) call,
  ];

  /// The blocks directly inside [path], [ktsOpaque] ones included (a
  /// container entry with a computed name, such as `create(name) { }`).
  List<KtsBlock> blocksIn(List<String> path) => [
    for (final block in blocks)
      if (block.path.length == path.length + 1 &&
          ktsPathIs(block.path.sublist(0, path.length), path))
        block,
  ];
}

/// A script Appstein can't read: a string, comment or bracket that is
/// never closed, or a bracket that closes nothing.
final class KtsFormatException implements Exception {
  /// Creates the exception.
  const KtsFormatException(this.message, this.line);

  /// What is wrong.
  final String message;

  /// The 1-based line where it starts.
  final int line;

  @override
  String toString() => 'line $line: $message';
}

/// Reads [text], a Gradle Kotlin script.
///
/// Throws a [KtsFormatException] when a string, comment or bracket is
/// never closed, or a bracket closes nothing.
KtsScript readKts(String text) {
  final parser = _Parser(_Tokenizer(text).run())..body(const []);
  return KtsScript(
    assignments: List.unmodifiable(parser.assignments),
    calls: List.unmodifiable(parser.calls),
    blocks: List.unmodifiable(parser.blocks),
  );
}

enum _Kind { name, string, number, symbol, newline, end }

final class _Token {
  const _Token(
    this.kind,
    this.text,
    this.line, {
    this.value,
  });

  final _Kind kind;
  final String text;
  final int line;

  /// A string's decoded value; null for a string with templates, a
  /// character literal, or any other token.
  final String? value;

  bool isSymbol(String symbol) => kind == _Kind.symbol && text == symbol;

  bool isName(String name) => kind == _Kind.name && text == name;
}

const _twoCharSymbols = {
  '==', '!=', '<=', '>=', '&&', '||', '->', '?.', '?:', '::', //
  '+=', '-=', '*=', '/=', '%=', '..', '++', '--', '!!',
};

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isNamePart(int c) => _isNameStart(c) || _isDigit(c);

final class _Tokenizer {
  _Tokenizer(this.source);

  final String source;
  final _tokens = <_Token>[];
  var _i = 0;
  var _line = 1;

  List<_Token> run() {
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      if (c == 0x0A) {
        _tokens.add(_Token(_Kind.newline, '\n', _line));
        _line++;
        _i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C) {
        _i++;
      } else if (source.startsWith('//', _i)) {
        while (_i < source.length && source.codeUnitAt(_i) != 0x0A) {
          _i++;
        }
      } else if (source.startsWith('/*', _i)) {
        _blockComment();
      } else if (c == 0x22) {
        _tokens.add(_string());
      } else if (c == 0x27) {
        _tokens.add(_char());
      } else if (c == 0x60) {
        _tokens.add(_backticked());
      } else if (_isNameStart(c)) {
        final start = _i;
        while (_i < source.length && _isNamePart(source.codeUnitAt(_i))) {
          _i++;
        }
        _tokens.add(_Token(_Kind.name, source.substring(start, _i), _line));
      } else if (_isDigit(c)) {
        _tokens.add(_number());
      } else {
        final two = _i + 1 < source.length ? source.substring(_i, _i + 2) : '';
        final text = _twoCharSymbols.contains(two) ? two : source[_i];
        _tokens.add(_Token(_Kind.symbol, text, _line));
        _i += text.length;
      }
    }
    _tokens.add(_Token(_Kind.end, '', _line));
    return _tokens;
  }

  void _blockComment() {
    final start = _line;
    var depth = 0;
    while (true) {
      if (_i >= source.length) {
        throw KtsFormatException('a comment is never closed', start);
      }
      if (source.startsWith('/*', _i)) {
        depth++;
        _i += 2;
      } else if (source.startsWith('*/', _i)) {
        depth--;
        _i += 2;
        if (depth == 0) return;
      } else {
        if (source.codeUnitAt(_i) == 0x0A) _line++;
        _i++;
      }
    }
  }

  _Token _number() {
    final start = _i;
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      final decimalPoint =
          c == 0x2E &&
          _i + 1 < source.length &&
          _isDigit(source.codeUnitAt(_i + 1));
      if (!_isNamePart(c) && !decimalPoint) break;
      _i++;
    }
    return _Token(_Kind.number, source.substring(start, _i), _line);
  }

  _Token _char() {
    final start = _i;
    final line = _line;
    _i++;
    while (true) {
      if (_i >= source.length || source.codeUnitAt(_i) == 0x0A) {
        throw KtsFormatException('a character literal is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      _i += c == 0x5C ? 2 : 1;
      if (c == 0x27) break;
    }
    return _Token(_Kind.string, source.substring(start, _i), line);
  }

  _Token _backticked() {
    final line = _line;
    final end = source.indexOf('`', _i + 1);
    if (end < 0 || source.substring(_i, end).contains('\n')) {
      throw KtsFormatException('a `name` is never closed', line);
    }
    final name = source.substring(_i + 1, end);
    _i = end + 1;
    return _Token(_Kind.name, name, line);
  }

  _Token _string() {
    final start = _i;
    final line = _line;
    final raw = source.startsWith('"""', _i);
    _i += raw ? 3 : 1;
    final value = StringBuffer();
    var template = false;
    while (true) {
      if (_i >= source.length) {
        throw KtsFormatException('a string is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      if (raw && source.startsWith('"""', _i)) {
        _i += 3;
        // `"""a""""` ends with a quote that belongs to the text.
        while (_i < source.length && source.codeUnitAt(_i) == 0x22) {
          value.write('"');
          _i++;
        }
        break;
      }
      if (!raw && c == 0x22) {
        _i++;
        break;
      }
      if (c == 0x0A) {
        if (!raw) throw KtsFormatException('a string is never closed', line);
        _line++;
      } else if (!raw && c == 0x5C) {
        _escape(value, line);
        continue;
      } else if (c == 0x24 && _i + 1 < source.length) {
        final next = source.codeUnitAt(_i + 1);
        if (next == 0x7B) {
          template = true;
          _i += 2;
          _templateBody(line);
          continue;
        }
        if (_isNameStart(next)) {
          template = true;
          _i++;
          while (_i < source.length && _isNamePart(source.codeUnitAt(_i))) {
            _i++;
          }
          continue;
        }
      }
      value.writeCharCode(c);
      _i++;
    }
    return _Token(
      _Kind.string,
      source.substring(start, _i),
      line,
      value: template ? null : value.toString(),
    );
  }

  void _escape(StringBuffer value, int line) {
    if (_i + 1 >= source.length) {
      throw KtsFormatException('a string is never closed', line);
    }
    final escaped = source[_i + 1];
    if (escaped == 'u' && _i + 5 < source.length) {
      final code = int.tryParse(source.substring(_i + 2, _i + 6), radix: 16);
      if (code != null) {
        value.writeCharCode(code);
        _i += 6;
        return;
      }
    }
    value.write(switch (escaped) {
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      'b' => '\b',
      _ => escaped,
    });
    _i += 2;
  }

  /// Skips a `${…}` template up to its closing brace, strings inside it
  /// included.
  void _templateBody(int line) {
    var depth = 1;
    while (depth > 0) {
      if (_i >= source.length) {
        throw KtsFormatException('a string is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      if (c == 0x22) {
        _string();
        continue;
      }
      if (c == 0x7B) depth++;
      if (c == 0x7D) depth--;
      if (c == 0x0A) _line++;
      _i++;
    }
  }
}

/// Calls whose trailing block is a container entry named by their string
/// argument, such as `create("dev") { … }`.
const _containerCalls = {
  'create', 'register', 'getByName', 'named', 'maybeCreate', //
};

const _controlWords = {
  'if', 'else', 'when', 'for', 'while', 'do', 'try', 'catch', 'finally', //
};

const _declarationWords = {
  'val', 'var', 'fun', 'import', 'package', 'class', 'object', //
  'interface', 'enum', 'typealias', 'return', 'throw', 'private', //
  'internal', 'public', 'protected', 'abstract', 'open', 'data', //
  'sealed', 'lateinit', 'const', 'override', 'inline',
};

/// Symbols after which a statement goes on to the next line.
const _continuesAfter = {
  '=', '.', '?.', ',', '+', '-', '*', '/', '%', '&&', '||', '?:', //
  '->', '..', '+=', '-=', '==', '!=', '<', '>', '<=', '>=', ':',
};

/// Symbols that, starting a line, continue the statement before.
const _continuesBefore = {'.', '?.', '?:', '&&', '||'};

final class _Parser {
  _Parser(this._tokens);

  final List<_Token> _tokens;
  var _pos = 0;
  final assignments = <KtsAssignment>[];
  final calls = <KtsCall>[];
  final blocks = <KtsBlock>[];

  _Token get _peek => _tokens[_pos];

  _Token _ahead(int offset) =>
      _tokens[(_pos + offset).clamp(0, _tokens.length - 1)];

  /// Reads statements up to the `}` that closes a block opened on
  /// [openLine] (and consumes it), or to the end of the script when
  /// [openLine] is null.
  void body(List<String> path, {int? openLine}) {
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.newline || token.isSymbol(';')) {
        _pos++;
      } else if (token.kind == _Kind.end) {
        if (openLine != null) {
          throw KtsFormatException('a block is never closed', openLine);
        }
        return;
      } else if (token.isSymbol('}')) {
        if (openLine == null) {
          throw KtsFormatException('a "}" closes no block', token.line);
        }
        _pos++;
        return;
      } else {
        _statement(path);
      }
    }
  }

  void _statement(List<String> path) {
    final token = _peek;
    if (token.kind == _Kind.name && _controlWords.contains(token.text)) {
      _control(path);
    } else if (token.kind == _Kind.name &&
        !_declarationWords.contains(token.text)) {
      _named(path);
    } else {
      _collect(path);
    }
  }

  /// `if (…) { … }`, `else`, `when (…) { … }`, loops and `try`: their
  /// bodies are read under [ktsOpaque].
  void _control(List<String> path) {
    _pos++;
    if (_peek.isSymbol('(')) _parenthesized(path);
    while (_peek.kind == _Kind.newline) {
      _pos++;
    }
    final inner = [...path, ktsOpaque];
    if (_peek.isSymbol('{')) {
      final open = _peek;
      _pos++;
      body(inner, openLine: open.line);
    } else if (_peek.kind != _Kind.end && !_peek.isSymbol('}')) {
      _statement(inner);
    }
  }

  /// A statement that starts with a name: an assignment, a block, a call,
  /// or something else.
  void _named(List<String> path) {
    final first = _peek;
    final names = [first.text];
    _pos++;
    while ((_peek.isSymbol('.') || _peek.isSymbol('?.')) &&
        _ahead(1).kind == _Kind.name) {
      names.add(_ahead(1).text);
      _pos += 2;
    }
    _typeArguments();
    final prefix = [...path, ...names.sublist(0, names.length - 1)];
    final next = _peek;
    if (next.isSymbol('=') || next.isSymbol('+=') || next.isSymbol('-=')) {
      _pos++;
      // `x =` with the value on the next line.
      while (_peek.kind == _Kind.newline) {
        _pos++;
      }
      final tokens = _collect(path);
      assignments.add(
        KtsAssignment(
          path: [...path, ...names],
          value: next.text == '='
              ? _classify(tokens)
              : KtsComputed(_shorten('${next.text} ${_join(tokens)}')),
          line: first.line,
        ),
      );
    } else if (next.isSymbol('{')) {
      _pos++;
      final blockPath = [...path, ...names];
      blocks.add(KtsBlock(path: blockPath, line: first.line));
      body(blockPath, openLine: next.line);
    } else if (next.isSymbol('(')) {
      final arguments = _parenthesized(path);
      if (_peek.isSymbol('{')) {
        final open = _peek;
        _pos++;
        final name = _containerCalls.contains(names.last)
            ? _plainString(arguments)
            : null;
        final blockPath = [...prefix, name ?? ktsOpaque];
        blocks.add(KtsBlock(path: blockPath, line: first.line));
        body(blockPath, openLine: open.line);
        return;
      }
      final infix = <String, KtsValue>{};
      while (_peek.kind == _Kind.name && _startsValue(_ahead(1))) {
        final word = _peek.text;
        _pos++;
        final valueTokens = [_peek];
        _pos++;
        while (valueTokens.last.kind == _Kind.name &&
            _peek.isSymbol('.') &&
            _ahead(1).kind == _Kind.name) {
          valueTokens.addAll([_peek, _ahead(1)]);
          _pos += 2;
        }
        if (_peek.isSymbol('(')) {
          valueTokens.add(_peek);
          valueTokens.addAll(_parenthesized(path));
          valueTokens.add(_Token(_Kind.symbol, ')', _peek.line));
        }
        infix[word] = _classify(valueTokens);
      }
      calls.add(
        KtsCall(
          path: prefix,
          name: names.last,
          arguments: _join(arguments),
          argument: _single(arguments),
          infix: infix,
          line: first.line,
        ),
      );
      // Whatever follows, such as `.apply { … }`.
      _collect(path);
    } else {
      _collect(path);
    }
  }

  bool _startsValue(_Token token) =>
      token.kind == _Kind.string ||
      token.kind == _Kind.number ||
      (token.kind == _Kind.name &&
          !_controlWords.contains(token.text) &&
          !_declarationWords.contains(token.text));

  /// Skips `<…>` after a name when it holds only type names and is
  /// followed by `(` or `{`, as in `tasks.register<Delete>("clean")`.
  void _typeArguments() {
    if (!_peek.isSymbol('<')) return;
    var depth = 0;
    var k = _pos;
    for (; k < _tokens.length; k++) {
      final token = _tokens[k];
      if (token.isSymbol('<')) {
        depth++;
      } else if (token.isSymbol('>')) {
        depth--;
        if (depth == 0) break;
      } else if (!(token.kind == _Kind.name ||
          token.isSymbol('.') ||
          token.isSymbol(',') ||
          token.isSymbol('?') ||
          token.isSymbol('*'))) {
        return;
      }
    }
    if (k + 1 >= _tokens.length) return;
    final after = _tokens[k + 1];
    if (after.isSymbol('(') || after.isSymbol('{')) _pos = k + 1;
  }

  /// Consumes `( … )` and returns the tokens inside, without newlines. A
  /// lambda inside is read under [ktsOpaque] and stands as `{…}`.
  List<_Token> _parenthesized(List<String> path) {
    final open = _peek;
    _pos++;
    final inner = <_Token>[];
    var depth = 1;
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.end) {
        throw KtsFormatException('a "(" is never closed', open.line);
      }
      if (token.isSymbol('{')) {
        _pos++;
        body([...path, ktsOpaque], openLine: token.line);
        inner.add(_Token(_Kind.symbol, '{…}', token.line));
        continue;
      }
      if (token.isSymbol('}')) {
        throw KtsFormatException('a "}" inside "( )"', token.line);
      }
      if (token.isSymbol('(') || token.isSymbol('[')) depth++;
      if (token.isSymbol(')') || token.isSymbol(']')) {
        depth--;
        if (depth == 0) {
          _pos++;
          return inner;
        }
      }
      if (token.kind != _Kind.newline) inner.add(token);
      _pos++;
    }
  }

  /// Consumes the rest of a statement and returns its tokens. Lambdas in
  /// it are read under [ktsOpaque] and stand as `{…}`. After `->` (a `when`
  /// branch), the rest is read as a statement of its own.
  List<_Token> _collect(List<String> path) {
    final tokens = <_Token>[];
    var depth = 0;
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.end) {
        if (depth > 0) {
          throw KtsFormatException('a bracket is never closed', token.line);
        }
        return tokens;
      }
      if (depth == 0 && (token.isSymbol(';') || token.isSymbol('}'))) {
        return tokens;
      }
      if (token.kind == _Kind.newline) {
        if (depth > 0 || _continues(tokens)) {
          _pos++;
          continue;
        }
        return tokens;
      }
      if (token.isSymbol('{')) {
        _pos++;
        body([...path, ktsOpaque], openLine: token.line);
        tokens.add(_Token(_Kind.symbol, '{…}', token.line));
        continue;
      }
      if (depth == 0 && token.isSymbol('->')) {
        _pos++;
        _statement(path.contains(ktsOpaque) ? path : [...path, ktsOpaque]);
        return tokens;
      }
      if (token.isSymbol('(') || token.isSymbol('[')) depth++;
      if (token.isSymbol(')') || token.isSymbol(']')) {
        if (depth == 0) {
          throw KtsFormatException(
            'a "${token.text}" closes nothing',
            token.line,
          );
        }
        depth--;
      }
      tokens.add(token);
      _pos++;
    }
  }

  /// Whether the statement in [tokens] goes on past the newline at the
  /// cursor.
  bool _continues(List<_Token> tokens) {
    // Nothing yet, such as after a call statement: the line ends it.
    if (tokens.isEmpty) return false;
    final last = tokens.last;
    if (last.kind == _Kind.symbol && _continuesAfter.contains(last.text)) {
      return true;
    }
    var k = _pos;
    while (_tokens[k].kind == _Kind.newline) {
      k++;
    }
    final next = _tokens[k];
    return next.kind == _Kind.symbol && _continuesBefore.contains(next.text);
  }

  KtsValue _classify(List<_Token> tokens) {
    final text = _join(tokens);
    if (tokens.length == 1) {
      final token = tokens.single;
      if (token.kind == _Kind.string && token.value != null) {
        return KtsString(token.value!, text);
      }
      if (token.kind == _Kind.number) {
        final number = int.tryParse(token.text);
        if (number != null) return KtsInt(number, text);
      }
      if (token.isName('true') || token.isName('false')) {
        return KtsBool(token.text == 'true', text);
      }
    }
    if (_isDottedName(tokens)) return KtsName(text);
    final n = tokens.length;
    if (n >= 4 &&
        tokens[n - 3].isSymbol('(') &&
        tokens[n - 1].isSymbol(')') &&
        tokens[n - 2].kind == _Kind.string &&
        tokens[n - 2].value != null &&
        _isDottedName(tokens.sublist(0, n - 3))) {
      return KtsCallValue(
        _join(tokens.sublist(0, n - 3)),
        tokens[n - 2].value!,
        text,
      );
    }
    return KtsComputed(_shorten(text));
  }

  KtsValue? _single(List<_Token> arguments) {
    if (arguments.isEmpty) return null;
    return switch (_classify(arguments)) {
      KtsComputed() || KtsCallValue() => null,
      final value => value,
    };
  }

  static String? _plainString(List<_Token> arguments) =>
      arguments.length == 1 && arguments.single.kind == _Kind.string
      ? arguments.single.value
      : null;

  static bool _isDottedName(List<_Token> tokens) {
    if (tokens.isEmpty || tokens.length.isEven) return false;
    for (var i = 0; i < tokens.length; i++) {
      final ok = i.isEven
          ? tokens[i].kind == _Kind.name &&
                !tokens[i].isName('true') &&
                !tokens[i].isName('false')
          : tokens[i].isSymbol('.');
      if (!ok) return false;
    }
    return true;
  }

  static String _join(List<_Token> tokens) {
    final out = StringBuffer();
    for (var k = 0; k < tokens.length; k++) {
      final token = tokens[k];
      if (k > 0) {
        final before = tokens[k - 1];
        final tight =
            token.isSymbol('.') ||
            token.isSymbol('?.') ||
            token.isSymbol(')') ||
            token.isSymbol(']') ||
            token.isSymbol(',') ||
            before.isSymbol('.') ||
            before.isSymbol('?.') ||
            before.isSymbol('(') ||
            before.isSymbol('[') ||
            ((token.isSymbol('(') || token.isSymbol('[')) &&
                before.kind == _Kind.name);
        if (!tight) out.write(' ');
      }
      out.write(token.text);
    }
    return out.toString();
  }

  static String _shorten(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 77)}...';
  }
}
```

The `//` after the first line of each `const` set keeps `dart format` from putting one entry per line; drop it if the formatter disagrees.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android/kts_reader_test.dart`
Expected: PASS. If a case fails, fix the reader, not the expectation, unless the expectation contradicts Kotlin. Then say which one in the report.

- [ ] **Step 5: Commit (controller)**

```bash
git add packages/appstein_engine
git commit -m "feat(android): a reader for Gradle Kotlin scripts"
```

---

### Task 4: The `.properties` and `AndroidManifest.xml` readers

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/android/properties_reader.dart`, `packages/appstein_engine/lib/src/packs/android/manifest_reader.dart`
- Modify: `packages/appstein_engine/pubspec.yaml`, `pubspec.lock` (by `pub get`)
- Test: `packages/appstein_engine/test/packs/android/properties_reader_test.dart`, `packages/appstein_engine/test/packs/android/manifest_reader_test.dart`

**Interfaces:**
- Consumes: `lineAt` (Task 2).
- Produces:
  - `PropertiesEntry(String value, int line)`; `Map<String, PropertiesEntry> readProperties(String text)`;
  - `androidNamespace`, `toolsNamespace`;
  - `ManifestAttribute(String value, int line)`;
  - `ManifestPermission({required String name, required int line, String? maxSdkVersion, bool removed, bool sdk23})`;
  - `ManifestFacts({ManifestAttribute? label, ManifestAttribute? icon, required List<ManifestPermission> permissions})`;
  - `ManifestFormatException(String message, [int? line])`;
  - `ManifestFacts readManifest(String text)`.

- [ ] **Step 1: Add the dependency**

In `packages/appstein_engine/pubspec.yaml`, add `xml: ^6.6.1` to `dependencies`, between `pub_semver` and `yaml`. Then run `fvm dart pub get` from the repo root. Flutter's own tool pins `xml: 6.6.1`.

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_engine/test/packs/android/properties_reader_test.dart`:

```dart
import 'package:appstein_engine/src/packs/android/properties_reader.dart';
import 'package:test/test.dart';

void main() {
  test("the template's gradle.properties", () {
    final entries = readProperties(
      'org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G\n'
      'android.useAndroidX=true\n'
      '# This newDsl flag was added by the Flutter template\n'
      'android.newDsl=false\n'
      '# This builtInKotlin flag was added by the Flutter template\n'
      'android.builtInKotlin=false\n',
    );
    expect(entries.keys, [
      'org.gradle.jvmargs',
      'android.useAndroidX',
      'android.newDsl',
      'android.builtInKotlin',
    ]);
    expect(entries['android.newDsl']!.value, 'false');
    expect(entries['android.newDsl']!.line, 4);
    expect(entries['android.builtInKotlin']!.line, 6);
  });

  test("the wrapper's escaped URL", () {
    final entries = readProperties(
      'distributionBase=GRADLE_USER_HOME\r\n'
      r'distributionUrl=https\://services.gradle.org/distributions/gradle-9.3.1-all.zip'
      '\r\n',
    );
    expect(
      entries['distributionUrl']!.value,
      'https://services.gradle.org/distributions/gradle-9.3.1-all.zip',
    );
    expect(entries['distributionUrl']!.line, 2);
  });

  test("Java's separators, comments, continuations and escapes", () {
    final entries = readProperties(
      '! a comment\n'
      '  spaced = value with spaces  \n'
      'colon:value\n'
      'blank value\n'
      'empty=\n'
      'long=first \\\n'
      '     second\n'
      r'unicode=café'
      '\n'
      r'key\ with\ space=1'
      '\n',
    );
    expect(entries['spaced']!.value, 'value with spaces  ');
    expect(entries['spaced']!.line, 2);
    expect(entries['colon']!.value, 'value');
    expect(entries['blank']!.value, 'value');
    expect(entries['empty']!.value, '');
    expect(entries['long']!.value, 'first second');
    expect(entries['long']!.line, 6);
    expect(entries['unicode']!.value, 'café');
    expect(entries['key with space']!.value, '1');
  });

  test('a key set twice keeps its last value, as in Java', () {
    final entries = readProperties('a=1\nb=2\na=3\n');
    expect(entries['a']!.value, '3');
    expect(entries['a']!.line, 3);
  });
}
```

Create `packages/appstein_engine/test/packs/android/manifest_reader_test.dart`:

```dart
import 'package:appstein_engine/src/packs/android/manifest_reader.dart';
import 'package:test/test.dart';

void main() {
  test("the template's main manifest: the label and icon lines are the "
      "attributes' own", () {
    final facts = readManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="probe_app"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true"/>
    </application>
</manifest>
''');
    expect(facts.label!.value, 'probe_app');
    expect(facts.label!.line, 3);
    expect(facts.icon!.value, '@mipmap/ic_launcher');
    expect(facts.icon!.line, 5);
    expect(facts.permissions, isEmpty);
  });

  test('permissions, with their extras, under any prefix', () {
    final facts = readManifest('''
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:a="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission a:name="android.permission.INTERNET"/>
    <uses-permission a:name="android.permission.WRITE_EXTERNAL_STORAGE"
        a:maxSdkVersion="28" />
    <uses-permission-sdk-23 a:name="android.permission.CAMERA"/>
    <uses-permission a:name="android.permission.RECORD_AUDIO" tools:node="remove"/>
    <application>
        <uses-permission a:name="not.a.real.place"/>
    </application>
</manifest>
''');
    expect(
      [for (final permission in facts.permissions) permission.name],
      [
        'android.permission.INTERNET',
        'android.permission.WRITE_EXTERNAL_STORAGE',
        'android.permission.CAMERA',
        'android.permission.RECORD_AUDIO',
      ],
    );
    expect(facts.permissions[0].line, 4);
    expect(facts.permissions[1].maxSdkVersion, '28');
    expect(facts.permissions[2].sdk23, isTrue);
    expect(facts.permissions[3].removed, isTrue);
    expect(facts.label, isNull);
  });

  test('broken XML is a ManifestFormatException with the line', () {
    expect(
      () => readManifest('<manifest>\n  <application>\n</manifest>\n'),
      throwsA(isA<ManifestFormatException>()),
    );
    expect(
      () => readManifest('<manifest>\n  <application a="1>\n</manifest>\n'),
      throwsA(
        isA<ManifestFormatException>().having((e) => e.line, 'line', 2),
      ),
    );
    expect(
      () => readManifest('<resources/>\n'),
      throwsA(isA<ManifestFormatException>()),
    );
  });
}
```

The broken-attribute case expects the parser's own line (2). If `package:xml` reports a different line for it, keep the test on the line it reports and say so in the report.

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android/properties_reader_test.dart test/packs/android/manifest_reader_test.dart`
Expected: FAIL to compile: the libraries don't exist.

- [ ] **Step 4: Write the readers**

Create `packages/appstein_engine/lib/src/packs/android/properties_reader.dart`:

```dart
/// One entry of a Java `.properties` file.
final class PropertiesEntry {
  /// Creates the entry.
  const PropertiesEntry(this.value, this.line);

  /// The value, with its escapes decoded.
  final String value;

  /// The 1-based line its key is on.
  final int line;
}

/// Reads a `.properties` file the way Java's `Properties.load` does. Gradle
/// reads `gradle.properties` and `gradle-wrapper.properties` with it:
/// - `#` and `!` start comment lines;
/// - `=`, `:` or white space separates a key from its value;
/// - a line ending in an odd number of `\` goes on to the next line;
/// - `\t`, `\n`, `\r`, `\f` and `\uXXXX` are decoded, and `\` before any
///   other character keeps that character.
///
/// A key set twice keeps its last value, as in Java.
Map<String, PropertiesEntry> readProperties(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  final entries = <String, PropertiesEntry>{};
  for (var i = 0; i < lines.length; i++) {
    final first = i;
    var line = _trimStart(lines[i]);
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    while (_continues(line) && i + 1 < lines.length) {
      i++;
      line = line.substring(0, line.length - 1) + _trimStart(lines[i]);
    }
    if (_continues(line)) line = line.substring(0, line.length - 1);
    final (key, value) = _split(line);
    entries.remove(_unescape(key));
    entries[_unescape(key)] = PropertiesEntry(_unescape(value), first + 1);
  }
  return entries;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\f';

String _trimStart(String line) {
  var i = 0;
  while (i < line.length && _isSpace(line[i])) {
    i++;
  }
  return line.substring(i);
}

bool _continues(String line) {
  var slashes = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

(String, String) _split(String line) {
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '=' || c == ':' || _isSpace(c)) break;
    i++;
  }
  final end = i < line.length ? i : line.length;
  var j = end;
  while (j < line.length && _isSpace(line[j])) {
    j++;
  }
  if (j < line.length && (line[j] == '=' || line[j] == ':')) {
    j++;
    while (j < line.length && _isSpace(line[j])) {
      j++;
    }
  }
  return (line.substring(0, end), line.substring(j));
}

String _unescape(String text) {
  if (!text.contains(r'\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c != r'\' || i + 1 >= text.length) {
      out.write(c);
      continue;
    }
    final next = text[++i];
    if (next == 'u' && i + 4 < text.length) {
      final code = int.tryParse(text.substring(i + 1, i + 5), radix: 16);
      if (code != null) {
        out.writeCharCode(code);
        i += 4;
        continue;
      }
    }
    out.write(switch (next) {
      't' => '\t',
      'n' => '\n',
      'r' => '\r',
      'f' => '\f',
      _ => next,
    });
  }
  return out.toString();
}
```

The `entries.remove` before the assignment makes a key set twice move to its last position, so the map's order is the order of the last settings. It's a detail; the keys are looked up, not listed in file order.

Create `packages/appstein_engine/lib/src/packs/android/manifest_reader.dart`:

```dart
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../native/native_files.dart';

/// The namespace of `android:` attributes.
const androidNamespace = 'http://schemas.android.com/apk/res/android';

/// The namespace of `tools:` attributes (the manifest merger's).
const toolsNamespace = 'http://schemas.android.com/tools';

/// An attribute's value and the 1-based line it is written on.
final class ManifestAttribute {
  /// Creates the attribute.
  const ManifestAttribute(this.value, this.line);

  /// The value, as written (a resource such as `@string/app_name` stays a
  /// resource).
  final String value;

  /// The line of the attribute itself.
  final int line;
}

/// A `<uses-permission>` or `<uses-permission-sdk-23>` of the manifest.
final class ManifestPermission {
  /// Creates the permission.
  const ManifestPermission({
    required this.name,
    required this.line,
    this.maxSdkVersion,
    this.removed = false,
    this.sdk23 = false,
  });

  /// Its `android:name`, such as `android.permission.CAMERA`.
  final String name;

  /// The line of its `android:name`.
  final int line;

  /// Its `android:maxSdkVersion`, as written; null when unset.
  final String? maxSdkVersion;

  /// Whether it has `tools:node="remove"`: it removes the permission a
  /// plugin's manifest would add.
  final bool removed;

  /// Whether it is a `<uses-permission-sdk-23>`.
  final bool sdk23;
}

/// What `native.json` records from one `AndroidManifest.xml`.
final class ManifestFacts {
  /// Creates the facts.
  const ManifestFacts({this.label, this.icon, required this.permissions});

  /// `<application android:label>`; null when unset.
  final ManifestAttribute? label;

  /// `<application android:icon>`; null when unset.
  final ManifestAttribute? icon;

  /// The permissions directly under `<manifest>`, in file order.
  final List<ManifestPermission> permissions;
}

/// A manifest Appstein can't read.
final class ManifestFormatException implements Exception {
  /// Creates the exception.
  const ManifestFormatException(this.message, [this.line]);

  /// What is wrong, in the XML parser's words.
  final String message;

  /// The 1-based line, when known.
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}

/// Reads an `AndroidManifest.xml` with `package:xml`'s event parser, which
/// knows where each element starts.
///
/// Throws a [ManifestFormatException] when the text isn't well-formed XML
/// or its root isn't `<manifest>`.
ManifestFacts readManifest(String text) {
  ManifestAttribute? label;
  ManifestAttribute? icon;
  final permissions = <ManifestPermission>[];
  var depth = 0;
  var sawRoot = false;
  try {
    for (final event in parseEvents(
      text,
      withLocation: true,
      withParent: true,
      validateNesting: true,
      validateDocument: true,
    )) {
      switch (event) {
        case XmlStartElementEvent():
          depth++;
          if (depth == 1) {
            if (event.localName != 'manifest') {
              throw ManifestFormatException(
                'the root element is <${event.name}>, not <manifest>',
                lineAt(text, event.start!),
              );
            }
            sawRoot = true;
          } else if (depth == 2) {
            ManifestAttribute? android(String local) =>
                _attribute(text, event, androidNamespace, local);
            switch (event.localName) {
              case 'application':
                label = android('label');
                icon = android('icon');
              case 'uses-permission' || 'uses-permission-sdk-23':
                if (android('name') case final name?) {
                  permissions.add(
                    ManifestPermission(
                      name: name.value,
                      line: name.line,
                      maxSdkVersion: android('maxSdkVersion')?.value,
                      removed:
                          _attribute(text, event, toolsNamespace, 'node')
                              ?.value ==
                          'remove',
                      sdk23: event.localName == 'uses-permission-sdk-23',
                    ),
                  );
                }
            }
          }
          if (event.isSelfClosing) depth--;
        case XmlEndElementEvent():
          depth--;
        default:
          break;
      }
    }
  } on XmlParserException catch (error) {
    throw ManifestFormatException(error.message, _line(error.line));
  } on XmlTagException catch (error) {
    throw ManifestFormatException(error.message, _line(error.line));
  } on XmlException catch (error) {
    throw ManifestFormatException(error.message);
  }
  if (!sawRoot) {
    throw const ManifestFormatException('there is no <manifest> element');
  }
  return ManifestFacts(label: label, icon: icon, permissions: permissions);
}

int? _line(int line) => line > 0 ? line : null;

/// The attribute [local] in [namespace] of [event], with the line it is
/// written on (found in the element's own text).
ManifestAttribute? _attribute(
  String text,
  XmlStartElementEvent event,
  String namespace,
  String local,
) {
  for (final attribute in event.attributes) {
    if (attribute.localName != local || attribute.namespaceUri != namespace) {
      continue;
    }
    final start = event.start!;
    final element = text.substring(start, event.stop ?? text.length);
    final match = RegExp(
      '(^|\\s)${RegExp.escape(attribute.name)}\\s*=',
    ).firstMatch(element);
    final offset = match == null ? 0 : match.start + match.group(1)!.length;
    return ManifestAttribute(attribute.value, lineAt(text, start + offset));
  }
  return null;
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android`
Expected: PASS. Then, from the repo root, `fvm dart run dependency_validator`: clean.

- [ ] **Step 6: Commit (controller)**

```bash
git add packages/appstein_engine pubspec.lock
git commit -m "feat(android): readers for .properties files and AndroidManifest.xml (package:xml)"
```

---

### Task 5: The `android` pack

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/android/android_native.dart`, `packages/appstein_engine/lib/src/packs/android/android_pack.dart`, `packages/appstein_engine/lib/android.dart`
- Create: the fixture tree `packages/appstein_engine/test/fixtures/native/template_app/` (Step 1)
- Create: `packages/appstein_engine/test/support/native_support.dart`
- Modify: `analysis_options.yaml` (repo root)
- Test: `packages/appstein_engine/test/packs/android/android_native_test.dart`

**Interfaces:**
- Consumes: Task 1's model; Task 2's `NativeContext`, `NativeSection`, `NativeExtractor`, `readNativeFile`, `loadPubspec`, `yamlLine`; Tasks 3 and 4's readers; `canonicalJson`; `Sourced<AndroidToolchain>`; `lineOf`, `copyFixtureTree`, `fixtureAppsDir` (test support).
- Produces:
  - `androidGradleProperties` (the listed keys);
  - `NativeSection readAndroidNative(NativeContext context)`;
  - `AndroidPack` (`id: 'android'`, `kind: PackKind.platform`, `version: '1'`, `nativeExtractor: AndroidNativeExtractor()`), `AndroidNativeExtractor` (`section: 'android'`);
  - `package:appstein_engine/android.dart`;
  - test support: `nativeTemplateDir`, `copyNativeTemplate()`, `writeProjectFiles(String root, Map<String, String> files)`, `flutterAndroidValues()`, `nativeContext(String projectRoot, {Map<String, String> variables, Sourced<AndroidToolchain>? android, String flutterVersion, String channel, HostOs? os})`.

**The `android` section's parts** (a part is a value unless it says group or list):

| Part | From | Found as |
|---|---|---|
| `buildLanguage` | which Gradle files exist | `kts`, `groovy` or `mixed` |
| `settings` (group) `agp`, `kgp`, `flutterPluginLoader` | `id(…) version "…"` in the `plugins { }` of `settings.gradle.kts` or `build.gradle.kts`, or a `buildscript` `classpath("…:version")` | the version |
| `gradle` (group) `version`, `distribution` | `distributionUrl` of `gradle-wrapper.properties` | `9.3.1`, `all` |
| `gradleProperties` (group) | `gradle.properties`: the three listed keys always, plus any `kotlin.*` key | the value as written |
| `app` (group) `plugins` | the `plugins { }` of `app/build.gradle.kts` | a list of ids |
| `app` `namespace`, `applicationId`, `ndkVersion`, `versionName` | `android { … }` | a string, or a `flutter.*` value resolved |
| `app` `compileSdk`, `minSdk`, `targetSdk`, `versionCode` | `android { … }` | an integer, or a `flutter.*` value resolved |
| `app` `javaSourceCompatibility`, `javaTargetCompatibility` | `compileOptions { }` | `JavaVersion.VERSION_17` |
| `app` `kotlinJvmTarget` | `kotlin { compilerOptions { jvmTarget } }` or `android { kotlinOptions { jvmTarget } }` | `…JvmTarget.JVM_17` or `"17"` |
| `app` `releaseSigningConfig` | `buildTypes { release { signingConfig = signingConfigs.getByName("…") } }` | the config's name |
| `app` `signingConfigs` | the blocks in `signingConfigs { }` | a list of names only |
| `app` `flavors` (list) | `productFlavors { create("…") { … } }` | per flavor, only what it sets |
| `manifests` (group) `main`, `debug`, `profile` (groups) | `app/src/<set>/AndroidManifest.xml` | `label`, `icon`, `permissions` (list) |

When a whole Gradle file can't be read (Groovy, both forms, unreadable, broken), the group that comes from it (`app`) or each value that needs it (`settings`) is that one `unknown` value.

- [ ] **Step 1: Make the template fixture from a real `flutter create`**

From the repo root (so FVM uses the pinned 3.47.5; in a folder without `.fvmrc`, `fvm flutter` falls back to the machine's global Flutter):

```bash
SCRATCH="<a scratch folder outside the repo>"
fvm flutter create --no-pub --platforms=android,ios --org dev.sample --project-name probe_app "$SCRATCH/probe_app"
fvm flutter pub get --directory "$SCRATCH/probe_app"
```

`pub get` writes the generated `Package.swift`. Then copy these files into `packages/appstein_engine/test/fixtures/native/template_app/`, each with `.fixture` added to its name (so `pubspec.yaml` becomes `pubspec.yaml.fixture`):

- `pubspec.yaml`
- `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/app/build.gradle.kts`
- `android/gradle.properties`, `android/gradle/wrapper/gradle-wrapper.properties`
- `android/app/src/main/AndroidManifest.xml`, `android/app/src/debug/AndroidManifest.xml`, `android/app/src/profile/AndroidManifest.xml`
- `ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`
- `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift`

Don't copy `local.properties` (it holds machine paths) or anything else. Check that no copied file contains a machine path: `grep -ril "users\|home/" packages/appstein_engine/test/fixtures/native` must print nothing. Check also that none is git-ignored: `git check-ignore -v <each file>` must print nothing (verified on 2026-10-02 for the `ephemeral` path).

Facts the tests rely on (checked on the development machine on 2026-10-02 against such an app; recheck with `lineOf` if your copy differs and report it):
- `settings.gradle.kts`: the plugin loader `1.0.0` on line 21, AGP `9.1.0` on 22, KGP `2.4.0` on 23;
- `gradle-wrapper.properties`: `gradle-9.3.1-all.zip` on line 5;
- `gradle.properties`: `android.useAndroidX=true` (2), `android.newDsl=false` (4), `android.builtInKotlin=false` (6);
- `app/build.gradle.kts`: the plugins `com.android.application` and `dev.flutter.flutter-gradle-plugin`, `JavaVersion.VERSION_17`, `JvmTarget.JVM_17`, release signed with `getByName("debug")`;
- `pubspec.yaml`: `version: 1.0.0+1` on line 19;
- the debug and profile manifests: `android.permission.INTERNET` on line 6.

- [ ] **Step 2: Add the test support**

Create `packages/appstein_engine/test/support/native_support.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import 'fake_sdk.dart';
import 'fixture_app.dart';
import 'flutter_fixtures.dart';
import 'temp.dart';

/// `test/fixtures/native/template_app`: the native files of a new app from
/// Flutter 3.47.5's `flutter create --platforms=android,ios --org
/// dev.sample --project-name probe_app`, after `flutter pub get`.
String get nativeTemplateDir =>
    p.join(p.dirname(fixtureAppsDir), 'native', 'template_app');

/// Copies the template into a new temp folder, as `native app`, and returns
/// that folder.
String copyNativeTemplate() {
  final app = p.join(tempDir().path, 'native app');
  copyFixtureTree(nativeTemplateDir, app);
  return app;
}

/// Writes [files] (a path relative to [root], with `/`, to its text).
void writeProjectFiles(String root, Map<String, String> files) {
  for (final MapEntry(key: path, value: text) in files.entries) {
    File(p.joinAll([root, ...path.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }
}

/// Flutter 3.47.5's Android values, read the way `sync` reads them: from
/// the SDK fixture's `gradle_utils.dart`.
Sourced<AndroidToolchain> flutterAndroidValues() {
  final sdk = p.join(tempDir().path, 'flutter');
  createFakeSdk(sdk);
  addToolchainFiles(sdk, '3.47.5');
  return readToolchain(
    sdk,
    flutterVersion: '3.47.5',
    notes: CuratedNotes.bundled(),
  ).toolchain.android!;
}

/// A [NativeContext] for the project at [projectRoot] on a machine with
/// only [variables]. `APPDATA` and `HOME` point at an empty temp folder,
/// so the real machine's Flutter settings are never read.
NativeContext nativeContext(
  String projectRoot, {
  Map<String, String> variables = const {},
  Sourced<AndroidToolchain>? android,
  String flutterVersion = '3.47.5',
  String channel = 'stable',
  HostOs? os,
}) {
  final home = tempDir().path;
  return NativeContext(
    projectRoot: projectRoot,
    flutterVersion: flutterVersion,
    channel: channel,
    environment: fakeEnvironment({
      'APPDATA': home,
      'HOME': home,
      ...variables,
    }, os: os),
    android: android,
  );
}
```

- [ ] **Step 3: Write the failing tests**

Create `packages/appstein_engine/test/packs/android/android_native_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

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
      expect(value(section, ['settings', 'flutterPluginLoader']).value, '1.0.0');
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
      expect(value(section, ['app', 'namespace']).value, 'dev.sample.probe_app');
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
      expect(value(section, ['app', 'signingConfigs']).status, NativeStatus.absent);
      expect(
        (section.node as NativeGroup).children['app']!.toJson(),
        containsPair('flavors', <Object?>[]),
      );
    });

    test('the manifests', () {
      expect(value(section, ['manifests', 'main', 'label']).value, 'probe_app');
      expect(
        value(section, ['manifests', 'main', 'icon']).toJson(),
        {
          'status': 'found',
          'value': '@mipmap/ic_launcher',
          'at': 'android/app/src/main/AndroidManifest.xml:5',
        },
      );
      final debug = NativeConfig({'android': section.node})
          .lookup(['android', 'manifests', 'debug', 'permissions'])!;
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
      expect(value(bare, ['app', 'minSdk']).reason, contains('flutter.minSdkVersion'));
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
      expect(value(section, ['settings', 'agp']).reason, "Groovy build files aren't read yet");
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
      expect(value(section, ['app', 'versionName']).status, NativeStatus.absent);
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
      final flavors = NativeConfig({'android': section.node})
          .lookup(['android', 'app', 'flavors'])!;
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

    test('AGP declared in settings and in a buildscript classpath is unknown',
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
    });

    test('damaged files: not UTF-8, broken XML, broken Kotlin, BOM and CRLF',
        () {
      File(p.join(app, 'android', 'gradle.properties'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([0xFF, 0xFE, 0x41]);
      writeProjectFiles(app, {
        'android/app/src/debug/AndroidManifest.xml': '<manifest>\n<oops>\n</manifest>\n',
        'android/settings.gradle.kts': 'plugins {\n  id("a"\n',
      });
      File(p.join(app, 'android', 'app', 'build.gradle.kts')).writeAsBytesSync([
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('android {\r\n    namespace = "crlf"\r\n}\r\n'),
      ]);
      final section = read(app);
      expect(
        value(section, ['gradleProperties']).toJson(),
        {
          'status': 'unknown',
          'reason': 'could not be read: not valid UTF-8',
          'at': 'android/gradle.properties',
        },
      );
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
    });
  });
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android/android_native_test.dart`
Expected: FAIL to compile: `android_native.dart` doesn't exist.

- [ ] **Step 5: Write the section builder**

Create `packages/appstein_engine/lib/src/packs/android/android_native.dart`:

```dart
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

NativeValue _computed(KtsValue written, String at) => NativeValue.unknown(
  'computed in Gradle code: `${written.text}`',
  at: at,
);

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
  final languages = {
    for (final file in files)
      if (file.language case final language?) language,
  };
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
    'applicationId': setting(['android', 'defaultConfig', 'applicationId'], text),
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
  return NativeValue.found(
    names.toList()..sort(),
    at: app.kts.at(lines.first),
  );
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
            'removed': NativeValue.found(true, at: file.at(declared.first.line)),
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
```

`Version.parse(…).toString()` returns the text as written (pub_semver keeps it), which is what Flutter splits on `+`.

- [ ] **Step 6: Write the pack and its library**

Create `packages/appstein_engine/lib/src/packs/android/android_pack.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/map_extractor.dart';
import '../../native/native_extractor.dart';
import '../pack.dart';
import 'android_native.dart';

/// The android platform pack (spec §10): Android's part of
/// `map/native.json`. Its checks arrive with the verifier (slice 1d).
final class AndroidPack implements Pack {
  /// Creates the pack.
  const AndroidPack();

  @override
  String get id => 'android';

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor get nativeExtractor => const AndroidNativeExtractor();
}

/// Writes the `android` section of `map/native.json`.
final class AndroidNativeExtractor implements NativeExtractor {
  /// Creates the extractor.
  const AndroidNativeExtractor();

  @override
  String get section => 'android';

  @override
  NativeSection extract(NativeContext context) => readAndroidNative(context);
}
```

Create `packages/appstein_engine/lib/android.dart`:

```dart
/// The android platform pack (spec §10), for the CLI to register. It is a
/// library of its own because the engine core never imports a pack (§5.1).
library;

export 'src/packs/android/android_pack.dart';
```

In the repo's `analysis_options.yaml`, change the `pack.android` tag to:

```yaml
    pack.android: [packages/appstein_engine/lib/src/packs/android/**, packages/appstein_engine/lib/android.dart]
```

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/android`
Expected: PASS. Then `fvm dart analyze --fatal-infos` from the repo root: clean (`layer_imports` included).

- [ ] **Step 8: Commit (controller)**

```bash
git add packages/appstein_engine analysis_options.yaml
git commit -m "feat(android): the android pack writes its native.json section, with the template fixture"
```

---

### Task 6: The property-list readers (`Info.plist`, `project.pbxproj`)

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/ios/plist_value.dart`, `packages/appstein_engine/lib/src/packs/ios/info_plist_reader.dart`, `packages/appstein_engine/lib/src/packs/ios/pbxproj_reader.dart`
- Test: `packages/appstein_engine/test/packs/ios/info_plist_reader_test.dart`, `packages/appstein_engine/test/packs/ios/pbxproj_reader_test.dart`

**Interfaces:**
- Consumes: `lineAt` (Task 2); `nativeTemplateDir` (Task 5's test support).
- Produces:
  - `sealed class PlistValue { int get line; }` with `PlistString(String value, int line)`, `PlistBool(bool value, int line)`, `PlistOther(String kind, String text, int line)`, `PlistArray(List<PlistValue> items, int line)`, `PlistDict(Map<String, PlistValue> entries, Map<String, int> keyLines, int line)`;
  - `PlistFormatException(String message, [int? line])`;
  - `PlistDict readXmlPlist(String text)`;
  - `PlistDict readPbxproj(String text)`.

Both iOS files are property lists. `Info.plist` is XML. `project.pbxproj` is the old "OpenStep" text format (`{ key = value; }`, `( a, b, )`, `/* comments */`), which Xcode writes and no Dart package reads. Flutter itself asks `plutil` on macOS, and edits the file as text in its migrations. Both readers build the same tree, with lines.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/packs/ios/info_plist_reader_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/src/packs/ios/info_plist_reader.dart';
import 'package:appstein_engine/src/packs/ios/plist_value.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/native_support.dart';

void main() {
  test("the template's Info.plist: strings, nested dicts and arrays, lines",
      () {
    final text = File(
      p.join(nativeTemplateDir, 'ios', 'Runner', 'Info.plist.fixture'),
    ).readAsStringSync();
    final dict = readXmlPlist(text);
    final lines = text.split('\n');
    int lineOf(String needle) =>
        lines.indexWhere((line) => line.contains(needle)) + 1;

    final display = dict.entries['CFBundleDisplayName']! as PlistString;
    expect(display.value, 'Probe App');
    expect(display.line, lineOf('<string>Probe App</string>'));
    expect(dict.keyLines['CFBundleDisplayName'], lineOf('CFBundleDisplayName'));
    expect(
      (dict.entries['CFBundleIdentifier']! as PlistString).value,
      r'$(PRODUCT_BUNDLE_IDENTIFIER)',
    );
    expect(
      (dict.entries['LSRequiresIPhoneOS']! as PlistBool).value,
      isTrue,
    );
    final scene = dict.entries['UIApplicationSceneManifest']! as PlistDict;
    final configurations =
        scene.entries['UISceneConfigurations']! as PlistDict;
    final roles =
        configurations.entries['UIWindowSceneSessionRoleApplication']!
            as PlistArray;
    final first = roles.items.single as PlistDict;
    final delegate = first.entries['UISceneDelegateClassName']! as PlistString;
    expect(delegate.value, r'$(PRODUCT_MODULE_NAME).SceneDelegate');
    expect(delegate.line, lineOf('SceneDelegate</string>'));
    expect(
      (dict.entries['UISupportedInterfaceOrientations']! as PlistArray)
          .items
          .length,
      3,
    );
  });

  test('integers, dates and escaped text', () {
    final dict = readXmlPlist('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Count</key>
  <integer>3</integer>
  <key>NSCameraUsageDescription</key>
  <string>Scans &amp; uploads</string>
  <key>Empty</key>
  <string/>
</dict>
</plist>
''');
    expect((dict.entries['Count']! as PlistOther).text, '3');
    expect((dict.entries['Count']! as PlistOther).kind, 'integer');
    expect(
      (dict.entries['NSCameraUsageDescription']! as PlistString).value,
      'Scans & uploads',
    );
    expect(dict.entries['NSCameraUsageDescription']!.line, 8);
    expect((dict.entries['Empty']! as PlistString).value, '');
  });

  test('what is not a readable property list is a PlistFormatException', () {
    for (final (text, message) in [
      ('bplist00\u0000\u0001', 'binary'),
      ('<plist><dict><key>a</key></dict></plist>', 'has no value'),
      ('<plist><dict><string>a</string></dict></plist>', 'without a <key>'),
      ('<plist><array/></plist>', 'no <dict>'),
      ('<plist><dict><key>a</key><string>b</dict></plist>', 'not valid XML'),
      ('<plist><dict><key>a</key><widget/></dict></plist>', 'unexpected'),
    ]) {
      expect(
        () => readXmlPlist(text),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
        reason: text,
      );
    }
  });
}
```

Create `packages/appstein_engine/test/packs/ios/pbxproj_reader_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/src/packs/ios/pbxproj_reader.dart';
import 'package:appstein_engine/src/packs/ios/plist_value.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/native_support.dart';

void main() {
  test('the old-style format: comments, quoted and bare strings, arrays, '
      'lines', () {
    final root = readPbxproj(r'''
// !$*UTF8*$!
{
	archiveVersion = 1;
	objects = {

/* Begin XCBuildConfiguration section */
		97C147061CF9000F007C117D /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = dev.sample.probeApp;
				INFOPLIST_FILE = Runner/Info.plist;
				OTHER = "a \"quoted\" value";
				LIST = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
			};
			name = Debug;
		};
/* End XCBuildConfiguration section */
	};
	rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''');
    final objects = root.entries['objects']! as PlistDict;
    final debug = objects.entries['97C147061CF9000F007C117D']! as PlistDict;
    expect(debug.line, 7);
    final settings = debug.entries['buildSettings']! as PlistDict;
    final id = settings.entries['PRODUCT_BUNDLE_IDENTIFIER']! as PlistString;
    expect(id.value, 'dev.sample.probeApp');
    expect(id.line, 10);
    expect(
      (settings.entries['INFOPLIST_FILE']! as PlistString).value,
      'Runner/Info.plist',
    );
    expect(
      (settings.entries['OTHER']! as PlistString).value,
      'a "quoted" value',
    );
    expect(
      [
        for (final item in (settings.entries['LIST']! as PlistArray).items)
          (item as PlistString).value,
      ],
      [r'$(inherited)', '@executable_path/Frameworks'],
    );
    expect(
      (root.entries['rootObject']! as PlistString).value,
      '97C146E61CF9000F007C117D',
    );
  });

  test("the template's project.pbxproj reads whole", () {
    final root = readPbxproj(
      File(
        p.join(
          nativeTemplateDir,
          'ios',
          'Runner.xcodeproj',
          'project.pbxproj.fixture',
        ),
      ).readAsStringSync(),
    );
    final objects = root.entries['objects']! as PlistDict;
    expect(objects.entries.length, greaterThan(20));
    final project =
        objects.entries[(root.entries['rootObject']! as PlistString).value]!
            as PlistDict;
    expect((project.entries['isa']! as PlistString).value, 'PBXProject');
  });

  test('JSON, a missing ";" or an unclosed comment is a PlistFormatException',
      () {
    for (final (text, line) in [
      ('{"objects": {}}', 1),
      ('{\n  a = b\n}\n', 3),
      ('{\n  /* never closed\n', 2),
      ('{\n  a = "never closed;\n}\n', 2),
      ('[1, 2]', 1),
    ]) {
      expect(
        () => readPbxproj(text),
        throwsA(isA<PlistFormatException>().having((e) => e.line, 'line', line)),
        reason: text,
      );
    }
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/ios`
Expected: FAIL to compile: the libraries don't exist.

- [ ] **Step 3: Write the model and the readers**

Create `packages/appstein_engine/lib/src/packs/ios/plist_value.dart`:

```dart
/// A value of a property list (`Info.plist`, `project.pbxproj`), with the
/// 1-based line it starts on.
sealed class PlistValue {
  const PlistValue(this.line);

  /// The line it starts on.
  final int line;
}

/// A string.
final class PlistString extends PlistValue {
  /// Creates the value.
  const PlistString(this.value, super.line);

  /// The text, with entities and escapes decoded.
  final String value;
}

/// `<true/>` or `<false/>`.
final class PlistBool extends PlistValue {
  /// Creates the value.
  const PlistBool(this.value, super.line);

  /// The boolean.
  final bool value;
}

/// An `<integer>`, `<real>`, `<date>` or `<data>`, kept as written.
final class PlistOther extends PlistValue {
  /// Creates the value.
  const PlistOther(this.kind, this.text, super.line);

  /// The element's name, such as `integer`.
  final String kind;

  /// Its text, trimmed.
  final String text;
}

/// An array.
final class PlistArray extends PlistValue {
  /// Creates the value.
  const PlistArray(this.items, super.line);

  /// The items, in order.
  final List<PlistValue> items;
}

/// A dictionary.
final class PlistDict extends PlistValue {
  /// Creates the value.
  const PlistDict(this.entries, this.keyLines, super.line);

  /// The values, by key, in file order.
  final Map<String, PlistValue> entries;

  /// The line of each key.
  final Map<String, int> keyLines;
}

/// A property list Appstein can't read.
final class PlistFormatException implements Exception {
  /// Creates the exception.
  const PlistFormatException(this.message, [this.line]);

  /// What is wrong.
  final String message;

  /// The 1-based line, when known.
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}
```

Create `packages/appstein_engine/lib/src/packs/ios/info_plist_reader.dart`:

```dart
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../native/native_files.dart';
import 'plist_value.dart';

const _leaves = {
  'key', 'string', 'integer', 'real', 'date', 'data', 'true', 'false', //
};

/// Reads an XML property list such as `Info.plist`, keeping each value's
/// line.
///
/// Throws a [PlistFormatException] for a binary property list, text that
/// isn't well-formed XML, or a property list whose root isn't a `<dict>`.
PlistDict readXmlPlist(String text) {
  if (text.startsWith('bplist')) {
    throw const PlistFormatException(
      "a binary property list, which Appstein doesn't read",
    );
  }
  final builder = _PlistBuilder(text);
  try {
    for (final event in parseEvents(
      text,
      withLocation: true,
      validateNesting: true,
      validateDocument: true,
    )) {
      builder.add(event);
    }
  } on XmlParserException catch (error) {
    throw PlistFormatException(
      'not valid XML: ${error.message}',
      error.line > 0 ? error.line : null,
    );
  } on XmlTagException catch (error) {
    throw PlistFormatException(
      'not valid XML: ${error.message}',
      error.line > 0 ? error.line : null,
    );
  } on XmlException catch (error) {
    throw PlistFormatException('not valid XML: ${error.message}');
  }
  final root = builder.root;
  if (root is! PlistDict) {
    throw const PlistFormatException(
      'the property list has no <dict> at its root',
    );
  }
  return root;
}

/// An element being read.
final class _Open {
  _Open(this.name, this.line);

  final String name;
  final int line;
  final items = <PlistValue>[];
  final entries = <String, PlistValue>{};
  final keyLines = <String, int>{};
  final text = StringBuffer();

  /// In a dict: the key waiting for its value, and its line.
  String? key;
  int? keyLine;
}

final class _PlistBuilder {
  _PlistBuilder(this.source);

  final String source;
  final _stack = <_Open>[];
  PlistValue? root;
  var _sawPlist = false;

  void add(XmlEvent event) {
    switch (event) {
      case XmlStartElementEvent(:final name, :final isSelfClosing):
        final line = lineAt(source, event.start!);
        if (name == 'plist') {
          if (_sawPlist) {
            throw PlistFormatException('a second <plist>', line);
          }
          _sawPlist = true;
        } else if (_stack.isEmpty) {
          throw PlistFormatException('<$name> outside <plist>', line);
        } else if (!_leaves.contains(name) &&
            name != 'dict' &&
            name != 'array') {
          throw PlistFormatException('unexpected <$name>', line);
        } else if (_leaves.contains(_stack.last.name)) {
          throw PlistFormatException(
            '<$name> inside <${_stack.last.name}>',
            line,
          );
        }
        _stack.add(_Open(name, line));
        if (isSelfClosing) _close();
      case XmlEndElementEvent():
        _close();
      case XmlTextEvent(:final value) || XmlCDATAEvent(:final value):
        if (_stack.isNotEmpty) _stack.last.text.write(value);
      default:
        break;
    }
  }

  void _close() {
    final open = _stack.removeLast();
    if (open.name == 'plist') {
      if (open.items.length != 1) {
        throw PlistFormatException(
          '<plist> must hold exactly one value',
          open.line,
        );
      }
      root = open.items.single;
      return;
    }
    final parent = _stack.last;
    if (open.name == 'key') {
      if (parent.name != 'dict') {
        throw PlistFormatException('<key> outside <dict>', open.line);
      }
      if (parent.key != null) {
        throw PlistFormatException(
          'the key "${parent.key}" has no value',
          parent.keyLine,
        );
      }
      parent
        ..key = open.text.toString()
        ..keyLine = open.line;
      return;
    }
    final PlistValue value;
    switch (open.name) {
      case 'dict':
        if (open.key != null) {
          throw PlistFormatException(
            'the key "${open.key}" has no value',
            open.keyLine,
          );
        }
        value = PlistDict(
          Map.unmodifiable(open.entries),
          Map.unmodifiable(open.keyLines),
          open.line,
        );
      case 'array':
        value = PlistArray(List.unmodifiable(open.items), open.line);
      case 'string':
        value = PlistString(open.text.toString(), open.line);
      case 'true' || 'false':
        value = PlistBool(open.name == 'true', open.line);
      default:
        value = PlistOther(open.name, open.text.toString().trim(), open.line);
    }
    if (parent.name == 'dict') {
      final key = parent.key;
      if (key == null) {
        throw PlistFormatException('a value without a <key>', open.line);
      }
      parent.entries[key] = value;
      parent.keyLines[key] = parent.keyLine!;
      parent
        ..key = null
        ..keyLine = null;
    } else {
      parent.items.add(value);
    }
  }
}
```

Create `packages/appstein_engine/lib/src/packs/ios/pbxproj_reader.dart`:

```dart
import 'plist_value.dart';

/// Reads an Xcode project file (`project.pbxproj`), written in the old
/// "OpenStep" property list format, keeping each value's line.
///
/// Throws a [PlistFormatException] when the text isn't in that format.
/// Xcode can also read a JSON project, but it never writes one.
PlistDict readPbxproj(String text) {
  final reader = _OpenStepReader(text)..skipSpace();
  if (!reader.at('{')) {
    throw PlistFormatException("not in Xcode's text format", reader.line);
  }
  final root = reader.value() as PlistDict;
  reader.skipSpace();
  if (!reader.done) {
    throw PlistFormatException('text after the end of the project', reader.line);
  }
  return root;
}

final class _OpenStepReader {
  _OpenStepReader(this.source);

  final String source;
  var _i = 0;
  var line = 1;

  bool get done => _i >= source.length;

  bool at(String char) => _i < source.length && source[_i] == char;

  void skipSpace() {
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      if (c == 0x0A) {
        line++;
        _i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0D) {
        _i++;
      } else if (source.startsWith('//', _i)) {
        while (_i < source.length && source.codeUnitAt(_i) != 0x0A) {
          _i++;
        }
      } else if (source.startsWith('/*', _i)) {
        final end = source.indexOf('*/', _i + 2);
        if (end < 0) {
          throw PlistFormatException('a comment is never closed', line);
        }
        for (var k = _i; k < end; k++) {
          if (source.codeUnitAt(k) == 0x0A) line++;
        }
        _i = end + 2;
      } else {
        return;
      }
    }
  }

  void _expect(String char) {
    skipSpace();
    if (!at(char)) {
      throw PlistFormatException(
        done
            ? 'the project ends early'
            : 'expected "$char" but found "${source[_i]}"',
        line,
      );
    }
    _i++;
  }

  PlistValue value() {
    skipSpace();
    if (done) throw PlistFormatException('the project ends early', line);
    final start = line;
    if (at('{')) {
      _i++;
      final entries = <String, PlistValue>{};
      final keyLines = <String, int>{};
      while (true) {
        skipSpace();
        if (at('}')) {
          _i++;
          return PlistDict(entries, keyLines, start);
        }
        final keyLine = line;
        final key = _string();
        _expect('=');
        entries[key] = value();
        keyLines[key] = keyLine;
        _expect(';');
      }
    }
    if (at('(')) {
      _i++;
      final items = <PlistValue>[];
      while (true) {
        skipSpace();
        if (at(')')) {
          _i++;
          return PlistArray(items, start);
        }
        items.add(value());
        skipSpace();
        if (at(',')) {
          _i++;
        } else if (!at(')')) {
          throw PlistFormatException('expected "," or ")"', line);
        }
      }
    }
    return PlistString(_string(), start);
  }

  String _string() {
    skipSpace();
    if (done) throw PlistFormatException('the project ends early', line);
    if (at('"')) return _quoted();
    final start = _i;
    while (_i < source.length && !_endsBare(source.codeUnitAt(_i))) {
      _i++;
    }
    if (_i == start) {
      throw PlistFormatException('unexpected "${source[_i]}"', line);
    }
    return source.substring(start, _i);
  }

  static bool _endsBare(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      '{}();,="'.codeUnits.contains(c);

  String _quoted() {
    final startLine = line;
    _i++;
    final out = StringBuffer();
    while (true) {
      if (_i >= source.length) {
        throw PlistFormatException('a string is never closed', startLine);
      }
      final c = source[_i];
      if (c == '"') {
        _i++;
        return out.toString();
      }
      if (c == r'\' && _i + 1 < source.length) {
        final escaped = source[_i + 1];
        _i += 2;
        if (escaped == 'U' && _i + 4 <= source.length) {
          final code = int.tryParse(source.substring(_i, _i + 4), radix: 16);
          if (code != null) {
            out.writeCharCode(code);
            _i += 4;
            continue;
          }
        }
        out.write(switch (escaped) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => escaped,
        });
        continue;
      }
      if (c == '\n') line++;
      out.write(c);
      _i++;
    }
  }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/ios`
Expected: PASS. The JSON case fails at line 1 with `expected "=" but found ":"`, after reading `"objects"` as a quoted key.

- [ ] **Step 5: Commit (controller)**

```bash
git add packages/appstein_engine
git commit -m "feat(ios): readers for XML property lists and project.pbxproj"
```

---

### Task 7: The `ios` pack, and the template's golden

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/ios/ios_files.dart`, `packages/appstein_engine/lib/src/packs/ios/swiftpm_setting.dart`, `packages/appstein_engine/lib/src/packs/ios/ios_native.dart`, `packages/appstein_engine/lib/src/packs/ios/ios_pack.dart`, `packages/appstein_engine/lib/ios.dart`
- Create: `packages/appstein_engine/test/fixtures/apps/goldens/native.json.golden` (by the golden test, then reviewed)
- Modify: `analysis_options.yaml` (repo root)
- Test: `packages/appstein_engine/test/packs/ios/ios_files_test.dart`, `packages/appstein_engine/test/packs/ios/swiftpm_setting_test.dart`, `packages/appstein_engine/test/packs/ios/ios_native_test.dart`, `packages/appstein_engine/test/native/native_template_test.dart`

**Interfaces:**
- Consumes: Task 2's seam and helpers; Task 6's readers; `readFlutterSettings` (`lib/src/android/flutter_settings.dart`, engine core); `HostEnvironment`; Task 5's `AndroidPack` and test support.
- Produces:
  - `GeneratedPackageFacts({required List<String> plugins, String? iosVersion, int? iosVersionLine})`, `GeneratedPackageFacts readGeneratedPackage(String text)`;
  - `PodfileFacts({String? version, int? line})`, `PodfileFacts readPodfile(String text)`;
  - `swiftPackageManagerSetting == 'enable-swift-package-manager'`, `swiftPackageManagerVariable == 'FLUTTER_SWIFT_PACKAGE_MANAGER'`;
  - `String? rawVariable(HostEnvironment environment, String name)`;
  - `NativeValue swiftPackageManagerEnabled({required YamlMap? pubspec, required Object? global, required String? variable, required String flutterVersion, required String channel})`;
  - `NativeSection readIosNative(NativeContext context)`;
  - `IosPack` (`id: 'ios'`, `kind: PackKind.platform`, `version: '1'`), `IosNativeExtractor` (`section: 'ios'`);
  - `package:appstein_engine/ios.dart`.

**The `ios` section's parts:**

| Part | From | Found as |
|---|---|---|
| `infoPlist` (group) `bundleIdentifier`, `displayName`, `bundleName`, `shortVersionString`, `bundleVersion` | `ios/Runner/Info.plist`: `CFBundleIdentifier`, `CFBundleDisplayName`, `CFBundleName`, `CFBundleShortVersionString`, `CFBundleVersion` | the string as written (`$(PRODUCT_BUNDLE_IDENTIFIER)` stays that) |
| `infoPlist` `sceneManifest`, `sceneDelegate` | `UIApplicationSceneManifest`, and its first `UISceneDelegateClassName` | `true`; the class name |
| `infoPlist` `usageDescriptions` (list) | every key ending in `UsageDescription` | per key, its `text` |
| `xcode` (group) `swiftPackageIntegrated` | `project.pbxproj` contains `FlutterGeneratedPluginSwiftPackage` (D8) | `true`/`false` |
| `xcode` `configurations` (list) | the Runner target's build configurations | per configuration: `bundleIdentifier`, `deploymentTarget`, `swiftVersion`, `developmentTeamSet` (D9) |
| `swiftPackageManager` (group) `enabled` | pubspec, global settings, environment, default (D4, D11) | `true`/`false` with `resolvedFrom` |
| `generatedPackage` (group) `iosVersion`, `plugins` | `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift` | `15.0`; plugin names (D10) |
| `podfile` (group) `platform`, `lockPresent` | `ios/Podfile`'s `platform :ios, '…'`; whether `ios/Podfile.lock` exists (D14) | the version; `true`/`false` |

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/packs/ios/ios_files_test.dart`:

```dart
import 'package:appstein_engine/src/packs/ios/ios_files.dart';
import 'package:test/test.dart';

void main() {
  test("the generated Package.swift: the iOS version and the plugins' names "
      'only', () {
    final facts = readGeneratedPackage('''
// swift-tools-version: 5.9
let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("15.0")
    ],
    dependencies: [
        .package(name: "url_launcher_ios", path: "/Users/me/.pub-cache/url_launcher_ios/ios/url_launcher_ios"),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "camera_avfoundation", path: "/Users/me/.pub-cache/camera_avfoundation/ios/camera_avfoundation")
    ],
)
''');
    expect(facts.iosVersion, '15.0');
    expect(facts.iosVersionLine, 5);
    expect(facts.plugins, ['camera_avfoundation', 'url_launcher_ios']);
  });

  test('a Package.swift with no plugins', () {
    final facts = readGeneratedPackage('platforms: [\n  .iOS("16.4")\n],\ndependencies: [\n\n],\n');
    expect(facts.iosVersion, '16.4');
    expect(facts.plugins, isEmpty);
  });

  test("the Podfile's platform line, and a commented one", () {
    final set = readPodfile(
      "# Uncomment this line\n  platform :ios, '13.0'\n\ntarget 'Runner' do\nend\n",
    );
    expect(set.version, '13.0');
    expect(set.line, 2);
    final commented = readPodfile("# platform :ios, '13.0'\n");
    expect(commented.line, isNull);
    final bare = readPodfile('platform :ios\n');
    expect(bare.line, 1);
    expect(bare.version, isNull);
  });
}
```

Create `packages/appstein_engine/test/packs/ios/swiftpm_setting_test.dart`:

```dart
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
    expect(decide(flutter: '3.41.6', channel: 'beta').status, NativeStatus.unknown);
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

  test('the global setting beats the environment; a non-boolean is unknown',
      () {
    expect(decide(global: false, variable: 'true').toJson(), {
      'status': 'found',
      'value': false,
      'resolvedFrom': 'flutter config (global)',
    });
    expect(decide(global: 'yes').status, NativeStatus.unknown);
  });

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
        pubspec: 'name: app\nflutter:\n  config:\n    enable-swift-package-manager:\n',
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
        pubspec: 'name: app\nflutter:\n  config:\n    enable-swift-package-manager: maybe\n',
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
```

Create `packages/appstein_engine/test/packs/ios/ios_native_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

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
        NativeConfig({'ios': section.node})
            .lookup(['ios', 'infoPlist', 'usageDescriptions'])!
            .toJson(),
        <Object?>[],
      );
    });

    test('Xcode: the Runner configurations, with the deployment target '
        'inherited from the project', () {
      expect(value(section, ['xcode', 'swiftPackageIntegrated']).value, isTrue);
      final configurations = NativeConfig({'ios': section.node})
          .lookup(['ios', 'xcode', 'configurations'])!;
      expect(
        [for (final entry in (configurations as NativeList).entries) entry.name],
        ['Debug', 'Profile', 'Release'],
      );
      final bundle =
          value(section, ['xcode', 'configurations', 'Debug', 'bundleIdentifier']);
      expect(bundle.value, 'dev.sample.probeApp');
      expect(bundle.note, isNull);
      expect(bundle.at, startsWith('ios/Runner.xcodeproj/project.pbxproj:'));
      final target =
          value(section, ['xcode', 'configurations', 'Release', 'deploymentTarget']);
      expect(target.value, '15.0');
      expect(target.note, 'set at project level');
      expect(
        value(section, ['xcode', 'configurations', 'Profile', 'swiftVersion']).value,
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
        NativeConfig({'ios': section.node})
            .lookup(['ios', 'infoPlist', 'usageDescriptions'])!
            .toJson(),
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
      expect(value(section, ['infoPlist', 'sceneManifest']).status, NativeStatus.absent);
      expect(
        value(section, ['generatedPackage']).reason,
        'not generated yet: `flutter pub get` writes it',
      );
    });

    test('a binary Info.plist, a JSON project and a project with no Runner',
        () {
      File(p.join(app, 'ios', 'Runner', 'Info.plist'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('bplist00');
      writeProjectFiles(app, {
        'ios/Runner.xcodeproj/project.pbxproj': '{"objects": {}}\n',
      });
      var section = read();
      expect(value(section, ['infoPlist']).reason, contains('binary'));
      expect(value(section, ['xcode', 'swiftPackageIntegrated']).value, isFalse);
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

    test("a Runner configuration's own settings, a team only as yes or no",
        () {
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
      expect(
        value(section, ['generatedPackage', 'plugins']).value,
        ['camera_avfoundation'],
      );
      expect(jsonEncode(section.node.toJson()), isNot(contains('/Users/me')));
    });

    test("the global settings file and the environment are read as Flutter "
        'reads them', () {
      writeProjectFiles(app, {'ios/Runner/Info.plist': '<plist><dict/></plist>'});
      final home = tempDir().path;
      File(p.join(home, '.flutter_settings'))
          .writeAsStringSync('{"enable-swift-package-manager": false}');
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
      final environment = read(variables: {'FLUTTER_SWIFT_PACKAGE_MANAGER': '1'});
      expect(value(environment, ['swiftPackageManager', 'enabled']).value, isFalse);
      expect(
        environment.inputs['env:FLUTTER_SWIFT_PACKAGE_MANAGER'],
        utf8.encode('1'),
      );
    });
  });
}
```

On macOS and Linux, Flutter reads `~/.flutter_settings` when it exists, so writing that file serves every OS; on Windows the same folder is `APPDATA`.

Create `packages/appstein_engine/test/native/native_template_test.dart`:

```dart
import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/native_support.dart';

void main() {
  test("the template app's native.json matches the golden", () {
    final build = const NativeSync(
      appsteinVersion: '0.1.0-dev',
      packs: [AndroidPack(), IosPack()],
    ).build(nativeContext(copyNativeTemplate(), android: flutterAndroidValues()));
    expect(build.report.errors, isEmpty);
    expect(build.report.sections, {'android': 'read', 'ios': 'read'});
    expectGolden('native.json', build.file!.body!);
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/ios test/native/native_template_test.dart`
Expected: FAIL to compile: the libraries don't exist.

- [ ] **Step 3: Write the small readers and the SwiftPM decision**

Create `packages/appstein_engine/lib/src/packs/ios/ios_files.dart`:

```dart
import '../../native/native_files.dart';

/// What `native.json` records from the `Package.swift` that
/// `flutter pub get` generates for the plugins.
final class GeneratedPackageFacts {
  /// Creates the facts.
  const GeneratedPackageFacts({
    required this.plugins,
    this.iosVersion,
    this.iosVersionLine,
  });

  /// The version in `.iOS("…")`, such as `15.0`; null when there is none.
  final String? iosVersion;

  /// The 1-based line of [iosVersion].
  final int? iosVersionLine;

  /// The plugins' package names, sorted, without Flutter's own
  /// `FlutterFramework`. Their paths are never read: they are absolute
  /// machine paths.
  final List<String> plugins;
}

/// Reads the generated `Package.swift`.
GeneratedPackageFacts readGeneratedPackage(String text) {
  final ios = RegExp(r'\.iOS\("([^"]+)"\)').firstMatch(text);
  final plugins = {
    for (final match in RegExp(
      r'\.package\(\s*name:\s*"([^"]+)"',
    ).allMatches(text))
      if (match[1] != 'FlutterFramework') match[1]!,
  }.toList()..sort();
  return GeneratedPackageFacts(
    plugins: plugins,
    iosVersion: ios?[1],
    iosVersionLine: ios == null ? null : lineAt(text, ios.start),
  );
}

/// What `native.json` records from a `Podfile`.
final class PodfileFacts {
  /// Creates the facts.
  const PodfileFacts({this.version, this.line});

  /// The version of its `platform :ios, '…'` line; null when the line has
  /// none, or there is no such line.
  final String? version;

  /// The 1-based line of its `platform :ios` line; null when there is none.
  final int? line;
}

/// Reads a `Podfile`'s `platform :ios` line. Commented lines don't count.
PodfileFacts readPodfile(String text) {
  final platform = RegExp(
    r'''^platform\s+:ios\b\s*(?:,\s*['"]([^'"]+)['"])?''',
  );
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final match = platform.firstMatch(lines[i].trim());
    if (match != null) return PodfileFacts(version: match[1], line: i + 1);
  }
  return const PodfileFacts();
}
```

Create `packages/appstein_engine/lib/src/packs/ios/swiftpm_setting.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../../host/host_environment.dart';
import '../../native/native_files.dart';

/// Flutter's name for the SwiftPM setting, in `pubspec.yaml`'s
/// `flutter: config:` and in `flutter config`.
const swiftPackageManagerSetting = 'enable-swift-package-manager';

/// The environment variable that sets SwiftPM.
const swiftPackageManagerVariable = 'FLUTTER_SWIFT_PACKAGE_MANAGER';

/// The environment variable [name] as Flutter reads it: an empty value
/// counts (decision D11), and on Windows names ignore case.
String? rawVariable(HostEnvironment environment, String name) {
  final exact = environment.variables[name];
  if (exact != null || environment.os != HostOs.windows) return exact;
  final wanted = name.toLowerCase();
  for (final MapEntry(:key, :value) in environment.variables.entries) {
    if (key.toLowerCase() == wanted) return value;
  }
  return null;
}

/// Whether SwiftPM is on for the project, decided as Flutter decides it
/// (`FlutterFeaturesConfig.isEnabled` in flutter_tools 3.47.5): first
/// `pubspec.yaml`'s `flutter: config:`, then the global settings [global]
/// that `flutter config` writes, then the environment [variable], then the
/// version's default (decision D4). A value Flutter would stop on (not a
/// boolean) is `unknown`.
NativeValue swiftPackageManagerEnabled({
  required YamlMap? pubspec,
  required Object? global,
  required String? variable,
  required String flutterVersion,
  required String channel,
}) {
  final flutter = pubspec?.nodes['flutter'];
  if (flutter is YamlMap) {
    final config = flutter.nodes['config'];
    if (config != null && config.value != null) {
      if (config is! YamlMap) {
        return NativeValue.unknown(
          '`flutter: config:` in pubspec.yaml must be a map; Flutter stops '
          'with an error',
          at: 'pubspec.yaml:${yamlLine(config)}',
        );
      }
      final setting = config.nodes[swiftPackageManagerSetting];
      if (setting != null && setting.value != null) {
        final at = 'pubspec.yaml:${yamlLine(setting)}';
        return switch (setting.value) {
          final bool enabled => NativeValue.found(
            enabled,
            at: at,
            resolvedFrom: 'pubspec.yaml',
          ),
          _ => NativeValue.unknown(
            '`$swiftPackageManagerSetting` in pubspec.yaml must be true or '
            'false; Flutter stops with an error',
            at: at,
          ),
        };
      }
    }
  }
  if (global != null) {
    return switch (global) {
      final bool enabled => NativeValue.found(
        enabled,
        resolvedFrom: 'flutter config (global)',
      ),
      _ => const NativeValue.unknown(
        '`$swiftPackageManagerSetting` in the global flutter config must be '
        'true or false; Flutter stops with an error',
      ),
    };
  }
  if (variable != null) {
    return NativeValue.found(
      variable.toLowerCase() == 'true',
      resolvedFrom: swiftPackageManagerVariable,
      note:
          'from the environment `appstein sync` ran in; a build started '
          'elsewhere may not have it',
    );
  }
  final Version version;
  try {
    version = Version.parse(flutterVersion);
  } on FormatException {
    return NativeValue.unknown(
      "Flutter $flutterVersion's default isn't known to Appstein",
    );
  }
  if (version >= Version(3, 44, 0)) {
    return const NativeValue.found(
      true,
      resolvedFrom: 'default',
      note: 'on by default since Flutter 3.44',
    );
  }
  if (channel == 'stable') {
    return const NativeValue.found(
      false,
      resolvedFrom: 'default',
      note: 'off by default before Flutter 3.44',
    );
  }
  return NativeValue.unknown(
    "the $channel channel's default before Flutter 3.44 isn't known to "
    'Appstein',
  );
}
```

- [ ] **Step 4: Write the section builder and the pack**

Create `packages/appstein_engine/lib/src/packs/ios/ios_native.dart`:

```dart
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
  final variable = rawVariable(context.environment, swiftPackageManagerVariable);
  inputs['flutter-config:$swiftPackageManagerSetting'] = utf8.encode(
    jsonEncode(global),
  );
  inputs['env:$swiftPackageManagerVariable'] = variable == null
      ? null
      : utf8.encode(variable);
  return NativeSection(
    NativeGroup({
      'infoPlist': _infoPlist(read(_infoPlistPath)),
      'xcode': _xcode(read(_pbxprojPath)),
      'swiftPackageManager': NativeGroup({
        'enabled': swiftPackageManagerEnabled(
          pubspec: loadPubspec(pubspec),
          global: global,
          variable: variable,
          flutterVersion: context.flutterVersion,
          channel: context.channel,
        ),
      }),
      'generatedPackage': _generatedPackage(read(_packagePath)),
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
    return NativeValue.found(delegate.value, at: file.at(delegate.line));
  }
  return NativeValue.absent(
    'no UISceneDelegateClassName in the scene manifest',
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
        if (object(id) case final configuration?)
          if (_text(configuration.entries['name']) case final name?)
            name: configuration,
    };
  }

  final targets = project.entries['targets'];
  final runner = [
    for (final id in targets is PlistArray ? targets.items : const <PlistValue>[])
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
  final projectConfigurations = configurationsOf(project);
  return NativeList([
    for (final MapEntry(key: name, value: configuration)
        in configurationsOf(runner.first).entries)
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
    if (inherited) 'set at project level',
    if (value.value.contains(r'$(')) 'uses Xcode build variables',
  ];
  return NativeValue.found(
    value.value,
    at: at,
    note: notes.isEmpty ? null : notes.join('; '),
  );
}

/// Whether a development team is set; the team's ID is never recorded.
NativeValue _team(PlistDict target, PlistDict? project, NativeFile file) {
  final (:value, :inherited) = _lookup(target, project, 'DEVELOPMENT_TEAM');
  if (value == null) return _notInProject('DEVELOPMENT_TEAM', file);
  return NativeValue.found(
    value is PlistString && value.value.isNotEmpty,
    at: file.at(value.line),
    note: inherited ? 'set at project level' : null,
  );
}

NativeNode _generatedPackage(NativeFile file) {
  if (!file.exists) {
    return const NativeValue.absent(
      'not generated yet: `flutter pub get` writes it',
    );
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
    'plugins': NativeValue.found(facts.plugins, at: file.path),
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
      (final version?, final line?) => NativeValue.found(
        version,
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
```

`flutter_settings.dart` lives in the engine core's `lib/src/android/` folder (slice 1b.1 wrote it for the doctor). It mirrors Flutter's `Config._configPath` exactly, `$XDG_CONFIG_HOME/settings` included (checked in Flutter 3.47.5's `base/config.dart`, lines 196–209), so the iOS pack may use it.

Create `packages/appstein_engine/lib/src/packs/ios/ios_pack.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/map_extractor.dart';
import '../../native/native_extractor.dart';
import '../pack.dart';
import 'ios_native.dart';

/// The ios platform pack (spec §10): iOS's part of `map/native.json`. Its
/// checks arrive with the verifier (slice 1d).
final class IosPack implements Pack {
  /// Creates the pack.
  const IosPack();

  @override
  String get id => 'ios';

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor get nativeExtractor => const IosNativeExtractor();
}

/// Writes the `ios` section of `map/native.json`.
final class IosNativeExtractor implements NativeExtractor {
  /// Creates the extractor.
  const IosNativeExtractor();

  @override
  String get section => 'ios';

  @override
  NativeSection extract(NativeContext context) => readIosNative(context);
}
```

Create `packages/appstein_engine/lib/ios.dart`:

```dart
/// The ios platform pack (spec §10), for the CLI to register. It is a
/// library of its own because the engine core never imports a pack (§5.1).
library;

export 'src/packs/ios/ios_pack.dart';
```

In the repo's `analysis_options.yaml`, change the `pack.ios` tag to:

```yaml
    pack.ios: [packages/appstein_engine/lib/src/packs/ios/**, packages/appstein_engine/lib/ios.dart]
```

- [ ] **Step 5: Run the tests; write and read the golden**

Run: `cd packages/appstein_engine && fvm dart test test/packs/ios`
Expected: PASS.

Then write the golden once and **read all of it** before going on (the slice 1b.5 lesson: reading real output found bugs that every test missed):

- `APPSTEIN_UPDATE_GOLDENS=1 fvm dart test test/native/native_template_test.dart`
- Read `test/fixtures/apps/goldens/native.json.golden` whole. Check every value against the fixture files by hand: each `at` points at the right line, nothing is `unknown` that the template states plainly, and nothing is `found` that the template doesn't state. List anything surprising in the report.
- `fvm dart test test/native/native_template_test.dart` without the variable: PASS.

- [ ] **Step 6: Run the engine's tests and the analyzer**

Run: `cd packages/appstein_engine && fvm dart test`, then `fvm dart analyze --fatal-infos` from the repo root.
Expected: PASS and clean.

- [ ] **Step 7: Commit (controller)**

```bash
git add packages/appstein_engine analysis_options.yaml
git commit -m "feat(ios): the ios pack writes its native.json section; the template's golden"
```

---

### Task 8: Write `native.json` in every sync

**Files:**
- Modify: `packages/appstein_engine/lib/src/knowledge/platform_sync.dart`, `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Modify: `packages/appstein_cli/lib/src/packs.dart`, `packages/appstein_cli/lib/src/sync_command.dart`
- Modify: `tool/measure_sync.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`, `packages/appstein_cli/test/packs_test.dart`, `packages/appstein_cli/test/sync_command_test.dart`

**Interfaces:**
- Consumes: `NativeSync`, `NativeContext`, `NativeReport` (Task 2); `AndroidPack` (Task 5); `IosPack` (Task 7); `nativeTemplateDir` (test support).
- Produces:
  - `PlatformBuild.toolchain` (`Toolchain`);
  - `SyncReport.native` (`NativeReport?`; null from `PlatformSync.run`);
  - `KnowledgeSync.run` writes `map/native.json` when a pack has a native extractor, after `MapSync` and whatever it did;
  - `packsFor` returns the stack pack, then one pack per platform;
  - `formatSyncReport` prints `Native config: <section> <outcome>; …` and each internal error in full.

- [ ] **Step 1: Write the failing engine tests**

In `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`:
- add the imports `package:appstein_engine/android.dart`, `package:appstein_engine/ios.dart` and `../support/native_support.dart`;
- add these top-level classes after the imports:

```dart
final class _BrokenExtractor implements NativeExtractor {
  const _BrokenExtractor();

  @override
  String get section => 'android';

  @override
  NativeSection extract(NativeContext context) => throw StateError('boom');
}

final class _BrokenPack implements Pack {
  const _BrokenPack();

  @override
  String get id => 'broken';

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor get nativeExtractor => const _BrokenExtractor();
}
```

- and add this group at the end of `main`:

```dart
  group('native config', () {
    const platformPacks = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

    void addTemplateNativeFiles(String app) {
      for (final folder in ['android', 'ios']) {
        copyFixtureTree(p.join(nativeTemplateDir, folder), p.join(app, folder));
      }
    }

    NativeValue nativeValue(String app, List<String> path) =>
        NativeConfig.fromJson(readMapBody(app, 'native.json')).lookup(path)!
            as NativeValue;

    test('with platform packs, native.json is written and listed in '
        'state.json; a project without android/ or ios/ gets absent '
        'sections', () async {
      final app = copyFixtureApp();
      final report = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect(report.files[MapFiles.native], isTrue);
      expect(readMapBody(app, 'native.json'), {
        'android': {'status': 'absent', 'reason': 'no android/ folder'},
        'ios': {'status': 'absent', 'reason': 'no ios/ folder'},
      });
      expect(report.native!.sections, {
        'android': 'absent: no android/ folder',
        'ios': 'absent: no ios/ folder',
      });
      expect((state(app)['files']! as Map).keys, contains(MapFiles.native));
    });

    test('when pub get fails, the map is skipped but native.json is still '
        'written', () async {
      final app = copyFixtureApp();
      addTemplateNativeFiles(app);
      File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
      runner.when(flutter(), [
        'pub',
        'get',
      ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
      final report = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect(report.map!.skipped, 'the packages could not be fetched');
      expect(report.files[MapFiles.native], isTrue);
      expect(nativeValue(app, ['android', 'app', 'minSdk']).toJson(), {
        'status': 'found',
        'value': 24,
        'at': 'android/app/build.gradle.kts:${lineOf(app, 'android/app/build.gradle.kts', 'minSdk =')}',
        'expression': 'flutter.minSdkVersion',
        'resolvedFrom': 'flutter',
      });
      expect(
        nativeValue(app, ['ios', 'generatedPackage', 'plugins']).value,
        isEmpty,
      );
    });

    test('an unchanged sync leaves native.json; the SwiftPM variable and the '
        'global setting rewrite it', () async {
      final app = copyFixtureApp();
      addTemplateNativeFiles(app);
      final home = tempDir().path;
      KnowledgeSync withVariables(Map<String, String> variables) =>
          KnowledgeSync(
            environment: fakeEnvironment({
              'FLUTTER_ROOT': sdk,
              'APPDATA': home,
              'HOME': home,
              ...variables,
            }),
            appsteinVersion: '0.1.0-dev',
            packs: platformPacks,
            runner: runner,
            clock: () => DateTime.utc(2026, 10, 1, 9),
          );
      Future<bool> nativeWritten(Map<String, String> variables) async =>
          (await withVariables(
            variables,
          ).run(app, dartSdkPath: testDartSdk)).files[MapFiles.native]!;

      expect(await nativeWritten({}), isTrue);
      expect(await nativeWritten({}), isFalse);
      expect(
        await nativeWritten({'FLUTTER_SWIFT_PACKAGE_MANAGER': 'false'}),
        isTrue,
      );
      expect(
        nativeValue(app, ['ios', 'swiftPackageManager', 'enabled']).value,
        isFalse,
      );
      File(
        p.join(home, '.flutter_settings'),
      ).writeAsStringSync('{"enable-swift-package-manager": true}');
      expect(
        await nativeWritten({'FLUTTER_SWIFT_PACKAGE_MANAGER': 'false'}),
        isTrue,
      );
      expect(
        nativeValue(app, ['ios', 'swiftPackageManager', 'enabled']).toJson(),
        {
          'status': 'found',
          'value': true,
          'resolvedFrom': 'flutter config (global)',
        },
      );
    });

    test('a native pack that fails costs only its section; the sync goes on',
        () async {
      final app = copyFixtureApp();
      final report = await sync(
        packs: const [OfficialMvvmPack(), _BrokenPack(), IosPack()],
      ).run(app, dartSdkPath: testDartSdk);
      expect(report.native!.errors, {'android': 'Bad state: boom'});
      expect(readMapBody(app, 'native.json')['android'], {
        'status': 'error',
        'errorType': 'StateError',
      });
      expect(report.files.keys, containsAll(MapFiles.all));
    });
  });
```

`copyFixtureTree`, `readMapBody` and `lineOf` come from `../support/fixture_app.dart`, which the file already imports; `NativeExtractor`, `NativeSection`, `NativeContext`, `MapExtractor`, `Pack` and `PackKind` from the engine; `LayerRules`, `NativeConfig` and `NativeValue` from the protocol.

- [ ] **Step 2: Write the failing CLI tests**

In `packages/appstein_cli/test/packs_test.dart`, add:

```dart
  test('every platform the config loader accepts has a pack', () {
    for (final platform in knownPlatforms) {
      final config = AppsteinConfig(packs: PacksConfig(platforms: [platform]));
      expect(
        [for (final pack in packsFor(config)) pack.id],
        contains(platform),
      );
    }
  });

  test('the default config gives the stack pack, then both platform packs',
      () {
    expect(
      [for (final pack in packsFor(const AppsteinConfig())) pack.id],
      ['official_mvvm', 'android', 'ios'],
    );
  });
```

In `packages/appstein_cli/test/sync_command_test.dart`:
- in `writes the platform layer and says what it did`, add:

```dart
    expect(text, contains(row('map/native.json', 'written')));
    expect(
      text,
      contains(
        'Native config: android absent: no android/ folder; ios absent: no '
        'ios/ folder.\n',
      ),
    );
```

- and add this test after the delta internal-error test:

```dart
  test('native config is one line, and an internal error is shown in full',
      () {
    const report = SyncReport(
      sdk: SdkInfo(
        flutterVersion: '3.47.5',
        dartVersion: '3.13.4',
        channel: 'stable',
        notesCoverage: NotesCoverage.complete,
      ),
      files: {'map/native.json': true},
      newestNotes: '3.47',
      fallbacks: [],
      native: NativeReport(
        sections: {
          'android': 'internal error (StateError)',
          'ios': 'absent: no ios/ folder',
        },
        errors: {'android': 'Bad state: boom\nmore'},
      ),
    );
    final text = formatSyncReport(report);
    expect(
      text,
      contains(
        'Native config: android internal error (StateError); ios absent: no '
        'ios/ folder.\n',
      ),
    );
    expect(
      text,
      contains(
        'Native config (android): missing because of an internal error in '
        'Appstein. Please report it, with this error:\n'
        '  Bad state: boom\n'
        '  more\n',
      ),
    );
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_test.dart` and `cd packages/appstein_cli && fvm dart test`
Expected: FAIL to compile: `SyncReport.native` doesn't exist.

- [ ] **Step 4: Wire the engine**

In `packages/appstein_engine/lib/src/knowledge/platform_sync.dart`:
- add `import '../native/native_sync.dart';`;
- add to `SyncReport` a named parameter `this.native` and the field:

```dart
  /// What the native-config part of the sync did; null when only the
  /// platform layer was synced ([PlatformSync.run]).
  final NativeReport? native;
```

- add to `PlatformBuild` a required parameter `this.toolchain` and the field:

```dart
  /// The toolchain matrix written to `toolchain.json`. Native config reads
  /// Flutter's Android values from it.
  final Toolchain toolchain;
```

- and pass `toolchain: reading.toolchain` where `build` creates the `PlatformBuild`.

In `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`:
- add `import '../native/native_extractor.dart';` and `import '../native/native_sync.dart';`;
- after the `final map = await MapSync(…).build(…);` statement, add:

```dart
    // Native config needs no analysis, so it is built even when the map was
    // skipped. It runs after MapSync because a `flutter pub get` the map ran
    // rewrites the generated Package.swift it reads.
    final native = NativeSync(appsteinVersion: appsteinVersion, packs: packs)
        .build(
          NativeContext(
            projectRoot: projectRoot,
            flutterVersion: platform.sdk.flutterVersion,
            channel: platform.sdk.channel,
            environment: environment,
            android: platform.toolchain.android,
          ),
        );
```

- change the list passed to `writeAll` to `[...platform.files, delta, ...map.files, if (native.file case final file?) file]`;
- add `native: native.report,` to the `SyncReport` it returns;
- in the doc comment of `KnowledgeSync`, change "the platform layer, the version delta and the project map" to "the platform layer, the version delta, the project map and the native config"; in the doc comment of `run`, add after the paragraph about the skipped map: "`map/native.json` is written either way: the platform packs read the native files without the analysis. A platform pack that fails costs only its own section, and the error is in [SyncReport.native]."

- [ ] **Step 5: Wire the CLI and the measurement**

Replace `packsFor` in `packages/appstein_cli/lib/src/packs.dart` with:

```dart
import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// The packs a project's `appstein.yaml` names (spec §7, §10): its stack
/// pack, then one pack per platform. The CLI chooses them because the
/// engine core never imports a pack (§5.1).
///
/// The config loader accepts only known stacks and platforms, each platform
/// once, so each has a pack.
List<Pack> packsFor(AppsteinConfig config) => [
  switch (config.packs.stack) {
    'official_mvvm' => const OfficialMvvmPack(),
    final stack => throw StateError('No pack for the stack "$stack".'),
  },
  for (final platform in config.packs.platforms)
    switch (platform) {
      'android' => const AndroidPack(),
      'ios' => const IosPack(),
      final other => throw StateError('No pack for the platform "$other".'),
    },
];
```

In `packages/appstein_cli/lib/src/sync_command.dart`, in `formatSyncReport`, add after the `if (map?.deltaError case final error?) { … }` block:

```dart
  if (report.native case final native?) {
    if (native.sections.isNotEmpty) {
      buffer.writeln(
        'Native config: '
        '${[for (final MapEntry(:key, :value) in native.sections.entries) '$key $value'].join('; ')}.',
      );
    }
    // An Appstein bug the user can't fix: ask for a report, with the whole
    // error (native.json names only its type).
    for (final MapEntry(key: section, value: error) in native.errors.entries) {
      buffer.writeln(
        'Native config ($section): missing because of an internal error in '
        'Appstein. Please report it, with this error:',
      );
      for (final line in const LineSplitter().convert(error)) {
        buffer.writeln('  $line');
      }
    }
  }
```

and update the doc comments: `SyncCommand`'s says it writes "the project map (`map/*.json`, `native.json` included)", and `formatSyncReport`'s lists "what native config found for each platform".

In `tool/measure_sync.dart`:
- import `package:appstein_engine/android.dart` and `package:appstein_engine/ios.dart`;
- use `packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()]`;
- at the end of `_generateApp`, give the app the template's native files, so the measurement includes reading them:

```dart
  // The native files of a new Flutter app, from the engine's test fixture
  // (the tool runs from the repo root).
  final template = p.join(
    'packages',
    'appstein_engine',
    'test',
    'fixtures',
    'native',
    'template_app',
  );
  for (final file in Directory(template).listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.fixture')) continue;
    final relative = p.relative(file.path, from: template);
    if (!relative.startsWith('android') && !relative.startsWith('ios')) {
      continue;
    }
    write(relative.substring(0, relative.length - '.fixture'.length),
        file.readAsStringSync());
  }
```

- and in its doc comment, say the app also has a new app's `android/` and `ios/` files.

- [ ] **Step 6: Run the tests to see them pass**

Run:
- `cd packages/appstein_engine && fvm dart test`
- `cd ../appstein_cli && fvm dart test`
- `fvm dart analyze --fatal-infos` from the repo root

Expected: all PASS and clean. Existing expectations that list every file of a sync with the platform packs must now include `map/native.json`; update only those, and name each one in the report.

- [ ] **Step 7: Commit (controller)**

```bash
git add packages tool/measure_sync.dart
git commit -m "feat: sync writes map/native.json from the platform packs, even when the map is skipped"
```

---

### Task 9: The real-SDK check

**Files:**
- Create: `packages/appstein_engine/test/integration/native_real_sdk_test.dart`
- Modify: `.github/workflows/ci.yml` (the `min-sdk` job's integration test list)

**Interfaces:**
- Consumes: everything above; `machineSdk` (test support); `SystemProcessRunner`; the real Flutter (3.47.5 locally and in the `test` job, 3.44 in `min-sdk`).

The test makes a new app with the real `flutter create`, with the template fixture's name and organization, then syncs it with the real environment. On 3.47.5 the result must equal the golden built from the fixture, which proves the fixture is what Flutter really writes. On 3.44 it checks only facts both versions share: the Kotlin build files (since 3.29), `flutter.minSdkVersion`, the three Xcode configurations, SwiftPM on (since 3.44.0) and a generated `Package.swift`.

- [ ] **Step 1: Write the test**

Create `packages/appstein_engine/test/integration/native_real_sdk_test.dart`:

```dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/machine_sdk.dart';
import '../support/temp.dart';

void main() {
  final environment = HostEnvironment.current();

  test('a new app from the real flutter create gives the native.json the '
      'template fixture gives', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final work = tempDir().path;
    final flutter = p.join(
      sdk.location!.root,
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );
    // The folder name has no space: `flutter create` names the project
    // after it unless told otherwise, and the parent's path already has a
    // space and a non-ASCII character.
    final created = await const SystemProcessRunner().run(
      flutter,
      [
        'create',
        '--no-pub',
        '--platforms=android,ios',
        '--org',
        'dev.sample',
        '--project-name',
        'probe_app',
        'native_app',
      ],
      workingDirectory: work,
      timeout: const Duration(minutes: 3),
    );
    expect(created.ok, isTrue, reason: '${created.stdout}\n${created.stderr}');
    final app = p.join(work, 'native_app');

    // The first sync fetches the packages, which writes Package.swift.
    final report = await KnowledgeSync(
      environment: environment,
      appsteinVersion: 'integration-test',
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
    ).run(app, sdk: sdk);
    expect(report.map!.skipped, isNull, reason: report.map!.packagesReason);
    expect(report.native!.errors, isEmpty);

    final body = readMapBody(app, 'native.json');
    final native = NativeConfig.fromJson(body);
    NativeValue value(List<String> path) =>
        native.lookup(path)! as NativeValue;

    // True on Flutter 3.44 and 3.47 alike.
    expect(value(['android', 'buildLanguage']).value, 'kts');
    expect(
      value(['android', 'app', 'minSdk']).expression,
      'flutter.minSdkVersion',
    );
    expect(value(['android', 'app', 'minSdk']).resolvedFrom, 'flutter');
    expect(value(['android', 'settings', 'agp']).status, NativeStatus.found);
    expect(value(['android', 'gradle', 'version']).status, NativeStatus.found);
    expect([
      for (final entry
          in (native.lookup(['ios', 'xcode', 'configurations'])! as NativeList)
              .entries)
        entry.name,
    ], ['Debug', 'Profile', 'Release']);
    expect(
      value([
        'ios',
        'xcode',
        'configurations',
        'Release',
        'deploymentTarget',
      ]).status,
      NativeStatus.found,
    );
    expect(
      value(['ios', 'generatedPackage', 'iosVersion']).status,
      NativeStatus.found,
    );
    final swiftPm = value(['ios', 'swiftPackageManager', 'enabled']);
    expect(swiftPm.status, NativeStatus.found);

    if (sdk.info!.flutterVersion != '3.47.5') return;
    if (swiftPm.resolvedFrom != 'default') {
      markTestSkipped(
        'SwiftPM is set on this machine (${swiftPm.resolvedFrom}), so '
        'native.json differs from the golden there.',
      );
      return;
    }
    expectGolden('native.json', body);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
```

- [ ] **Step 2: Run it against the real SDK**

Run: `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration test/integration/native_real_sdk_test.dart`
Expected: PASS. It needs the network for `cupertino_icons` the first time. If the golden differs, read the real `native.json` and the fixture side by side, and decide whether the fixture, the code or the assumption is wrong. Report it; never refresh the golden from the real run to make it pass.

- [ ] **Step 3: Run it in the `min-sdk` job too**

In `.github/workflows/ci.yml`, the `min-sdk` job's step "Read the toolchain and map the fixture app with this real SDK" runs a list of integration test files. Add `test/integration/native_real_sdk_test.dart` to that `dart test` command. The `test` job already runs every integration test.

- [ ] **Step 4: Run every test once, and measure**

- `cd packages/appstein_engine && fvm dart test`, then `fvm dart test --run-skipped --tags integration`
- `cd ../appstein_cli && fvm dart test`; `cd ../appstein_protocol && fvm dart test`; `cd ../appstein_lints && fvm dart test`
- from the repo root: `fvm dart test test` (the repo tool tests) and `fvm dart run tool/measure_sync.dart`

Expected: all PASS; the full sync stays under 30 s (slice 1b.5 measured 15.4 s on Windows). Record the time in the report.

- [ ] **Step 5: Commit (controller)**

```bash
git add packages/appstein_engine/test/integration/native_real_sdk_test.dart .github/workflows/ci.yml
git commit -m "test: native.json from a real flutter create equals the template's golden"
```

---

### Task 10: The developer guide

**Files:**
- Create: `docs/guide/native-config.md`
- Modify: `docs/guide/project-map.md`, `docs/guide/knowledge-store.md`, `docs/guide/architecture.md`, `docs/guide/cli.md`, `docs/guide/config.md`, `docs/guide/testing.md`, `docs/guide/ci.md`, `docs/guide/README.md`

**Interfaces:**
- Consumes: everything built in Tasks 1–9.

- [ ] **Step 1: Write the new page**

Create `docs/guide/native-config.md`. Its first lines are the covers block:

```markdown
<!-- covers:
packages/appstein_engine/lib/src/native/**
packages/appstein_engine/lib/src/packs/android/**
packages/appstein_engine/lib/src/packs/ios/**
packages/appstein_engine/lib/android.dart
packages/appstein_engine/lib/ios.dart
-->
```

Then these sections, in plain words, for someone who has never opened a Gradle file. Every claim must match the code as built; quote file names and links the way `version-delta.md` does:

1. **What the file holds** (`# Native config`): `.appstein/map/native.json` (spec §6.5) is the Android and iOS setup an agent needs before it touches native code. One section per platform pack, with the two tables of parts from Tasks 5 and 7, shortened to one row per group.
2. **Every value says how sure it is:** the four statuses, `at`, `expression`, `resolvedFrom` and `note`, with a short example of each. Why `unknown` is never a guess. Why the project's names (flavors, permissions, configurations) are list entries (D2).
3. **Reading Gradle without running Gradle:** what `readKts` follows and what it doesn't; the `?` segment; set twice, conditional, old forms and `afterEvaluate` as `unknown`. Why not Gradle itself (it needs a JDK, takes tens of seconds, may need the network; the verifier's cheap gate runs Flutter's `--config-only` build for exactness in slice 1d). Groovy files: not read yet, a future item (spec §18 M3).
4. **Flutter's own values:** how `flutter.minSdkVersion` and the others become numbers (D3), with the source files named: `gradle_utils.dart` through `toolchain.json`, `FlutterExtension.kt`, `FlutterPlugin.kt`'s defaults, the `pubspec.yaml` `version:` rules. Note that `--build-number`/`--build-name` at build time override the pubspec, and `native.json` can't know them.
5. **iOS files:** the two property-list readers and why there are two; the Runner target and project-level inheritance (D9); why `Package.swift` exists on Windows too (`flutter pub get` writes it); why there's usually no Podfile.
6. **SwiftPM, decided as Flutter decides:** the order (pubspec, global settings, environment, default), with Flutter's misleading comment called out: `flutter_features.dart` says "environment variable > project manifest > global config", but `FlutterFeaturesConfig.isEnabled` checks the environment last. Only `true` turns it on; an empty value counts. The default is on since stable 3.44.0.
7. **No secrets, no machine paths:** the rules from the Global Constraints and where each is enforced.
8. **How sync builds it:** `NativeSync` after `MapSync`, why after (Package.swift), why independent (decision 2 of the brainstorm: offline still gives native facts), the per-section error rule (D12), the duplicate-section `StateError` (D13), and the input hash: every file read, the global setting's value, the variable, Flutter's Android values, the Flutter version and channel, and the packs.
9. **Tests:** the reader tests, `fixtures/native/template_app` and how to remake it (Task 5 Step 1), the `native.json` golden, and the real-SDK test that compares a real `flutter create` with the golden.

- [ ] **Step 2: Update the existing pages**

1. **`project-map.md`:**
   - Replace line 23 ("`native.json`, the Android and iOS configuration, comes in slice 1b.4. It will be written by the platform packs, …") with: "`native.json`, the Android and iOS configuration, is written by the platform packs from the native files, without the analysis. It has [its own page](native-config.md)."
   - In the "How sync builds it" diagram, add before the `renderDelta` line: `|-- NativeSync.build        map/native.json, from the platform packs (no writing yet)`.
   - In "Two things to notice", add to the bullet about a skipped map: "`map/native.json` is still written then."
   - In "Packs and the core", add that a pack now has `nativeExtractor`: platform packs use it, stack packs return null; and that two packs writing one map file, or one native section, is a `StateError`.
2. **`knowledge-store.md`:**
   - In the intro, replace "Native config (1b.4), and `INDEX.md` and incremental sync (1b.6), come in later slices." with "Slice 1b.4 added **native config**, `map/native.json`, which has [its own page](native-config.md). `INDEX.md` and incremental sync (1b.6) come in a later slice."
   - Add this row after the `features.json`, `routes.json` row: `| .appstein/map/native.json | The Android and iOS setup, each value with where it was found (see [native-config](native-config.md)) | a native file, pubspec.yaml, the SwiftPM setting outside the project, the Flutter version or a pack changes, or the file was hand-edited or damaged |`, with the path in backticks like the other rows.
   - In the `state.json` row, change "When the map was skipped, it lists only the platform files and `delta.md`" to "When the map was skipped, it lists only the platform files, `delta.md` and `map/native.json`".
   - In the flowchart, add `run --> native["NativeSync.build:<br/>native.json"]` after the `MapSync.build` line, and in the numbered list a step for it, before `writeAll`, renumbering; `writeAll`'s order becomes "platform files, `delta.md`, map files, `native.json`, then `state.json` last".
3. **`architecture.md`:**
   - Line 21: "Native config, the verifier, …" becomes "The verifier, more packs and the MCP server come in later slices".
   - In "What exists now", add native config to the knowledge bullet, linking [native-config](native-config.md).
   - In the engine table, add a row after `map/`: `| native/ | Native config: the extractor seam and NativeSync, which writes native.json from the platform packs | [native-config](native-config.md) |`, with code in backticks like the other rows; and wherever packs are listed, add `android` and `ios` (`lib/android.dart`, `lib/ios.dart`).
4. **`cli.md`:** in "`appstein sync`", step 2 says `packsFor` turns `packs.stack` **and `packs.platforms`** into packs: `official_mvvm` gives `OfficialMvvmPack`, `android` and `ios` give `AndroidPack` and `IosPack`. In the output description, add the `Native config:` line and the internal-error report.
5. **`config.md`:** in "Where config is used today", the `appstein sync` bullet adds that `packs.platforms` chooses the platform packs, which write `native.json` ([native-config](native-config.md)).
6. **`testing.md`:** add `fixtures/native/template_app/` (a real 3.47.5 `flutter create`, how to remake it), the `native_support.dart` helpers (`nativeContext` points `APPDATA` and `HOME` at a temp folder so the real Flutter settings are never read), and `native.json.golden` under "Goldens".
7. **`ci.md`:** `tool/measure_sync.dart` now gives the measured app a new app's `android/` and `ios/` files and runs the platform packs; the `min-sdk` job also runs `native_real_sdk_test.dart`.
8. **`README.md`** (the guide map): add after the `version-delta` row: `| [native-config](native-config.md) | How appstein sync reads the Android and iOS setup into native.json, and why a value is found, unknown or absent |`, with code in backticks like the other rows.

- [ ] **Step 3: Regenerate and check**

From the repo root:
- `fvm dart run tool/gen_docs.dart`
- `fvm dart run tool/check_guide.dart --since main`

Expected: `gen_docs` updates the generated sections (such as the engine's export list); the guide check passes: every new source file is covered, and every changed page is newer than its code.

- [ ] **Step 4: Commit (controller)**

```bash
git add docs/guide
git commit -m "docs: native config in the guide (spec §19.6)"
```

---

### Task 11: Verify, read the real output, open the PR, record (controller)

- [ ] **Step 1: Full local verification**

From the repo root:
- `fvm dart analyze --fatal-infos`
- `fvm dart format --output=none --set-exit-if-changed .`
- `fvm dart run dependency_validator`
- each package's tests, plus `fvm dart test --run-skipped --tags integration` in the engine
- `fvm dart test test` (the repo tool tests)
- `fvm dart run tool/gen_docs.dart` and `fvm dart run tool/gen_notes.dart` (no change)
- `fvm dart run tool/check_guide.dart --since main`
- `dart doc --dry-run` in `packages/appstein_engine` and `packages/appstein_protocol` (0 warnings)
- the BOM scan

- [ ] **Step 2: Read the real output (the slice 1b.5 lesson)**

On the development machine, with the compiled CLI (`fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe`):
1. **A new app:** in the scratchpad, from the repo root, `fvm flutter create --platforms=android,ios <scratch>/fresh_app`, then `appstein sync --project <scratch>/fresh_app`. Read the whole `native.json`. Run `sync` a second time: `map/native.json  unchanged`.
2. **An app with real plugins:** add `camera`, `url_launcher` and `permission_handler` to it (`fvm flutter pub add …` run from the repo root with `--directory`), add a `NSCameraUsageDescription` to its `Info.plist` and a `CAMERA` permission to its main manifest, then sync again. Read the whole `native.json`: the generated `Package.swift` lists the plugins (a Podfile appears only if one of them still needs CocoaPods; check which), the permission and usage description appear with their lines, and no machine path or secret appears anywhere (`grep` it for the user's home folder).
3. **A Groovy-era project, if one is at hand** (any project created before Flutter 3.29): sync it and read the `android` section.

Show the owner the sizes and a sample of each section, and list anything surprising. Fix what reading finds before the PR.

- [ ] **Step 3: Push `slice-1b4` and open the PR**

PR body:
- what the slice adds;
- the owner's rulings: Kotlin files only (Groovy a future item), independent of the map, expression and number for `flutter.*`, SwiftPM decided as Flutter decides, approach A (platform packs), design parts 1–3, spec edits E1–E5;
- the decisions D1–D14;
- the verification results, with the real-output reading.

The body ends with the session's PR attribution lines. CI must be green on all jobs, including `min-sdk` (Flutter 3.44) and `measure`, with the logs checked to show the new tests ran.

- [ ] **Step 4: One commit after the PR opens**

- Append "## Notes from execution" to this plan (outside any code fence).
- In `docs/superpowers/progress.yaml`, set 1b.4 to `status: done` with `pr: <n>` and `finished: <date>`, and mark 1b.6 `next`.
- Run `fvm dart run tool/gen_docs.dart`, then **read back the rendered `.html`**: 1b.4 Done with its PR link, 1b.6 Next (owner rule, 2026-10-01).

Push it.

- [ ] **Step 5: Graph and merge**

Run `/graphify . --update` until `tool/check_graph.py` reports nothing, with at most 3 extraction subagents (see the graph runbook in memory: old-label checklists for big docs, `set -o pipefail`, no `| tail`). Then merge by the owner's PR flow and delete the branch.

## Carried to later slices

- **Future, if needed (owner, 2026-10-02):** reading Groovy Gradle build files, for projects created before Flutter 3.29 (spec §18 M3).
- **1d (verify):**
  - the §9.2 Android and iOS checks read `native.json` through `NativeConfig.lookup`;
  - the plugin↔permission mapping and the plugin graph (which plugins need `minSdk`, SwiftPM or CocoaPods) come from the resolved packages there, not from `native.json`;
  - the AppDelegate pattern and `PrivacyInfo.xcprivacy` are checked there;
  - `knowledge.stale` compares `native.json`'s `meta.inputHash` like the other map files.
- **1c (MCP):** `native.md` (§6.9) renders `native.json`; typed accessors may be added to `NativeConfig` if the renderer needs them (D1).
- **1b.6:** INDEX.md's app and bundle IDs (§6.3) come from `native.json`; incremental sync rebuilds `native.json` only when its own inputs change (its hash already allows it).
- **Known limits, recorded here:**
  - values set only in `.xcconfig` files, or by Gradle code, are `unknown`, never read;
  - `--build-number` and `--build-name` given at build time aren't known to `native.json`;
  - a flavor created by a call without a block (`create("x")` alone) isn't listed.
- **Still carried from 1b.3:** an unexpected exception in the map build (an analyzer bug) still aborts the whole sync; `native.json` and the delta each have their own catch, the map doesn't.

## Notes from execution (2026-10-02)

Executed in quick subagent-driven mode, with at most 3 subagents at once. Every task had a task review (Opus for the readers, the section builders and the seam), then came a final whole-branch review on Opus, one fix wave, a scoped re-review, and one more ruled round (below). PR #10 in the old private repo.

**Pre-flight scan.** It found no conflicts between tasks. One ruling: each task is committed right after its implementer reports, and fixes land as follow-up commits, so the review script can diff commits while subagents never commit.

**The plan's own code guessed, and reviews caught it.** Opus reviewers ran throwaway probes against each reader and section builder. About fifteen realistic inputs gave a wrong `found` or an `absent` for a value that is set. Each now gives `unknown` with a reason:
- **`readKts`:**
  - `import java.util.*` or a generic type at a line end swallowed the next block, `android { }` included;
  - scope functions (`apply`, `run`, `with`, `let`, `also`, `configure<…>`) and collection callbacks (`all { }`, `configureEach { }`) hid assignments or became flavor names;
  - entries under `if`, `by creating` and `create("x").apply { }` vanished;
  - `version "8." + "1.0"` read as `"8."`.
  - Every opaque body now leaves a `?` block, and nested scope bodies are read at most three levels deep, so a pathological file stays linear.
- **The `android` section:**
  - a damaged `pubspec.yaml` gave a confident default version;
  - `alias(…)` plugins and `id(…).version(…)` chains read as "not declared";
  - flavors created by calls, and flavors using old names, were lost;
  - keys set where the reader doesn't follow read as "not set": `tasks.withType<…>().configureEach { … }`, `getByName("release").apply { … }`, `jvmTarget.set(…)`, `jvmToolchain(…)`, toolchain blocks, AGP's block form `compileSdk { version = release(36) }`, `it.`/`this.` receivers and `setX(…)` calls;
  - a release build with no signing config of its own uses `defaultConfig`'s, unless a flavor signs its own builds;
  - a key set twice on one line is "set more than once".
  - A backstop now turns any key the reader saw but can't place into `unknown`.
- **The `ios` section:**
  - a bad `\U` escape could crash the extractor;
  - a Podfile version written as a Ruby expression, as `"#{…}"`, with an `if` modifier, inside a Ruby block, twice, or in a CRLF file was misread;
  - an unreadable `pubspec.yaml` silently dropped out of the SwiftPM decision;
  - several `absent` reasons said something false.
  - Info.plist values using `$(…)` carry the build-variables note. A project-level Xcode value notes that the target's `.xcconfig` can override it.

**Reading the real output found one more.** On Windows and Linux, `flutter pub get` writes the generated `Package.swift` as a placeholder with no plugins, even for an app with iOS plugins. Flutter fills it only when Swift Package Manager is in use, which needs Xcode 15 or later (`xcode_project.dart:214-238`, `darwin_dependency_management.dart:62-75`). So `generatedPackage.plugins` is found only when the file depends on `FlutterFramework`, which Flutter always adds when SwiftPM is in use. The template fixture was made on Windows, so its golden says `unknown`. The real-SDK test expects `found []` on a Mac with Xcode, deciding from the generated file.

**One extra round, by ruling.** The final fix wave introduced two new false claims: flavors in nested scope functions read as `[]`, and `minSdk = 21; minSdk = 23` on one line read as 21. The process allows one fix wave, but these were false claims, and this plan's Task 11 says to fix what the reading finds. So one more round fixed them, with the `Package.swift` finding and a manifest wording fix. Its scoped re-review approved merging.

**Windows line endings.** `flutter create` on Windows writes CRLF files, and git stores the fixtures as LF. The fixture folder was re-checked out as LF before the golden was generated. The golden holds no hash, and the real-SDK test compares the body, not `meta`, so CRLF doesn't matter there.

**Corrections to this plan's text.**
- "A flavor created by a call without a block isn't listed" (Carried, known limits) is no longer true: such flavors are listed with only their name.
- Containers declared more than three scope functions deep can still be missed. That limit is in the guide.

**Numbers.**
- **Tests:** engine 617, protocol 56, CLI 34, lints 19, engine integration 7, repo tools 212.
- **`measure_sync` on Windows:** full sync 13.2 s, against the 30 s target; first sync 23.2 s; both native sections read.
- **Real output** (compiled CLI, Flutter 3.47.5):
  - A fresh app gives an 11 KB `native.json`, every value matching the files; a second sync left it unchanged.
  - With `camera`, `url_launcher` and `permission_handler`, the `CAMERA` permission and the usage description appear with their lines, and no machine path appears.
  - Without an FVM pin, the machine's Flutter 3.38.6 failed `pub get`, the map was skipped, and `native.json` was still written.
- **Not checked locally:** a Groovy-era project (none on this machine; unit tests cover it), the real-SDK test's macOS branch, and the Flutter 3.44 job.

**Left by ruling.** AGP declared only in the app's own `plugins { }` block reads as "not declared in settings", which is literally true and rare.

**Parked (minor; the final review rated each "can wait"):**
- the OS's own wording for an unreadable file reaches `reason` and the hash;
- `MapSync`'s duplicate check doesn't cover symbols, layers or deps;
- a `\` before a newline inside a Kotlin string is accepted, and later lines shift by one;
- an unclosed bracket reports the end-of-file line;
- a malformed `\uXXXX` in `.properties` becomes letters;
- unknown pbxproj escapes become the letter;
- duplicate plist keys keep the last value silently;
- the XML plist reader accepts stray text;
- `val dc = android.defaultConfig; dc.minSdk = 21` reads as "not set";
- `the<AppExtension>()` and `extensions.configure<…>` without an `android` receiver aren't followed;
- `platform :ios, ''` is labelled a Ruby expression;
- a few test gaps (the channel and packs in the hash test, the environment-source SwiftPM note, permission children).
