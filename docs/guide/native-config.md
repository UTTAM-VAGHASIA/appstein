<!-- covers:
packages/appstein_engine/lib/src/native/**
packages/appstein_engine/lib/src/packs/android/**
packages/appstein_engine/lib/src/packs/ios/**
packages/appstein_engine/lib/android.dart
packages/appstein_engine/lib/ios.dart
-->

# Native config

`appstein sync` writes `.appstein/map/native.json` (spec §6.5). It is the Android and iOS setup an agent needs to know before it touches native code: the app's id, the minimum Android and iOS versions, the permissions, the flavors, the Xcode configurations. An agent reads it instead of opening Gradle and Xcode files, which are long and written for tools, not for people. This page explains what is in the file, how each value is read, and the limits of that reading. The file's format is in the protocol package ([`native_config.dart`](../../packages/appstein_protocol/lib/src/map/native_config.dart)), and the decisions behind it are in the [slice 1b.4 plan](../superpowers/plans/2026-10-02-slice-1b4-native-config.md#decisions-made-while-planning-for-the-owners-review).

## What the file holds

One section per platform pack: `android`, written by the `android` pack, and `ios`, written by the `ios` pack. Each section is a tree. A **value** is one fact. A **group** holds parts with names Appstein chose. A **list** holds things the project named itself.

### The `android` section

| Part | What it holds | Read from |
|---|---|---|
| `buildLanguage` | `kts`, `groovy` or `mixed`: how the Gradle files are written | which of `build.gradle.kts` or `build.gradle` exist, in the three Gradle files below |
| `settings` | `agp` (the Android Gradle Plugin), `kgp` (the Kotlin plugin) and `flutterPluginLoader`: the plugin versions | `android/settings.gradle.kts`, then `android/build.gradle.kts` |
| `gradle` | `version` and `distribution` (`bin` or `all`) of the Gradle the project downloads | `android/gradle/wrapper/gradle-wrapper.properties` |
| `gradleProperties` | `android.useAndroidX`, `android.newDsl`, `android.builtInKotlin`, and every key starting with `kotlin.` | `android/gradle.properties` |
| `app` | the app module's setup: `plugins`, `namespace`, `applicationId`, `compileSdk`, `minSdk`, `targetSdk`, `ndkVersion`, `versionCode`, `versionName`, the Java and Kotlin versions, `releaseSigningConfig`, `signingConfigs` (names only) and `flavors` (a list) | `android/app/build.gradle.kts`, and `pubspec.yaml` for `flutter.versionCode` and `flutter.versionName` |
| `manifests` | for each of `main`, `debug` and `profile`: the app's `label` and `icon`, and its `permissions` (a list) | `android/app/src/<set>/AndroidManifest.xml` |

### The `ios` section

| Part | What it holds | Read from |
|---|---|---|
| `infoPlist` | the bundle id, names, version strings, whether the app uses scenes and its scene delegate, and `usageDescriptions` (a list: the permission texts such as `NSCameraUsageDescription`) | `ios/Runner/Info.plist` |
| `xcode` | `swiftPackageIntegrated`, and `configurations` (a list: `Debug`, `Profile`, `Release`), each with its bundle id, deployment target, Swift version and whether a development team is set | `ios/Runner.xcodeproj/project.pbxproj` |
| `swiftPackageManager` | `enabled`: Flutter's SwiftPM feature setting (Swift Package Manager). It is the setting, not a promise that the plugins build with SwiftPM: Flutter also needs Xcode 15 or later and an app that isn't an add-to-app module (`compatibleWithSwiftPackageManager` in Flutter's `xcode_project.dart`) | decided as Flutter decides it, see [below](#swiftpm-decided-as-flutter-decides) |
| `generatedPackage` | `iosVersion` and the `plugins` that Flutter's generated package lists | `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift` |
| `podfile` | `platform` (the iOS version) and `lockPresent` (whether `Podfile.lock` exists) | `ios/Podfile`, `ios/Podfile.lock` |

When a whole folder is missing, the whole section is one `absent` value (`no android/ folder`, `no ios/ folder`). When one file is missing, only the values that need it say so.

## Every value says how sure it is

A value is never a bare number. It is an object with a `status`, and what else it holds depends on the status ([`NativeValue`](../../packages/appstein_protocol/lib/src/map/native_config.dart)):

| Status | Meaning | Holds |
|---|---|---|
| `found` | The file states it plainly | `value`, and `at`, `expression`, `resolvedFrom` and `note` when they apply |
| `unknown` | It is there, but not as a plain value Appstein can read | `reason`, and `at` |
| `absent` | It isn't set, or its file doesn't exist | `reason`, and sometimes `at` |
| `error` | The platform pack crashed (an Appstein bug). Only a whole section has this | `errorType` |

The other fields:

- **`at`** is where the value is: `path` or `path:line`, relative to the project, with `/` on every OS.
- **`expression`** is how the file wrote it, when that isn't the value itself: `flutter.minSdkVersion`.
- **`resolvedFrom`** says where the value of an expression or a setting came from: `flutter`, `notes`, `pubspec.yaml:19`, `default`, `flutter config (global)`.
- **`note`** is anything else a reader must know: `set at project level`, `on by default since Flutter 3.44`.

Four examples, shortened from the real file ([`native.json.golden`](../../packages/appstein_engine/test/fixtures/apps/goldens/native.json.golden), made from a new app):

```text
"compileSdk": {                                    found, from an expression
  "at": "android/app/build.gradle.kts:9",
  "expression": "flutter.compileSdkVersion",
  "resolvedFrom": "flutter",
  "status": "found",
  "value": 36 }

"developmentTeamSet": {                            unknown
  "at": "ios/Runner.xcodeproj/project.pbxproj",
  "reason": "DEVELOPMENT_TEAM is not in project.pbxproj; it may come from an .xcconfig file",
  "status": "unknown" }

"signingConfigs": {                                absent
  "reason": "no signing configs in android/app/build.gradle.kts",
  "status": "absent" }

"android": { "status": "error", "errorType": "StateError" }      error: a whole section
```

**Why `unknown` is never a guess.** An agent that is told `minSdk` is 21 will write code for 21. If Appstein guessed, and the real value was 26, the code would be wrong and nobody would know why. `unknown` with a reason ("set more than once (lines 12, 40)") sends the agent to the file, which is the right move. This is spec §6.5: never guess. So a value is `found` only when the file states it plainly, and everything else says what stopped Appstein. An `unknown` is also better than an `absent` when something might set the value somewhere Appstein doesn't look: it is `absent` only when nothing in the file could set it. "Nothing could set it" means no assignment, call or block that the reader sees names the key. What it still misses is a key set through a variable receiver (`val dc = android.defaultConfig; dc.minSdk = 21`), because the reader doesn't follow variables.

**Why the project's own names are list entries.** Flavors, permissions, usage descriptions and Xcode configurations are names the project chose. If they were JSON keys, a flavor named `status`, the key that marks a value, would break the file. So each is an entry of a list, `{"name": "dev", "at": "...", ...}`, sorted by name, and the parts of the entry sit next to its `name`. `NativeConfig.lookup(['android', 'app', 'flavors', 'dev', 'minSdk'])` still finds a part by path, with the entry's name as one step.

## Reading Gradle without running Gradle

Android's settings live in Gradle build files. Gradle files are programs, so the exact answer comes from running Gradle. Appstein doesn't:

- Gradle needs a JDK, takes tens of seconds, and may need the network.
- `appstein sync` runs on every change and must stay fast, and it must give facts even when the tools aren't installed.
- The exact answer will come in slice 1d, where the verifier's cheap gate runs Flutter's own `--config-only` build.

Instead, [`readKts`](../../packages/appstein_engine/lib/src/packs/android/kts_reader.dart) reads Gradle's Kotlin build files (`.gradle.kts`) the way a person scans them. It is not a Kotlin parser.

**What it follows:**
- strings (a string with a `$` template is not a plain string), comments (nested `/* */` too), numbers and brackets;
- `name { ... }` blocks, so `android { defaultConfig { minSdk = 24 } }` and `android.defaultConfig.minSdk = 24` both give the path `android > defaultConfig > minSdk`;
- assignments (`=`, `+=`, `-=`), and call statements such as `id("x") version "1.0"`;
- container entries, `create("dev") { }`, `register(...)`, `getByName(...)`, `named(...)` and `maybeCreate(...)`, which name a flavor or a signing config.

A scope function's body (`defaultConfig.apply { }`) is read twice, as inside the receiver and as inside the outer block, because the reader can't tell a DSL receiver from a plain value. Only the three outermost levels of scope bodies are read twice (at most 8 copies of the innermost body); a deeper one is read once, so the cost is bounded, not 2 to the power of the depth. The copies are identical, so a key is counted once per line and value: `minSdk = 21; minSdk = 23` on one line is still "set more than once".

**What it does not follow.** The inside of an `if`, `when`, loop or `try`, a lambda passed to a call, a scope function (`apply`, `run`, `with`, `configure`, `let`, `also`) and a collection callback (`all`, `forEach`, `configureEach`, `withType`, `matching`, `filter`, ...) is still read, but under a path segment `?`. So a value set there is seen and reported as conditional. It is never missed, and never taken for a plain setting. A `?` in a path means "somewhere Appstein doesn't follow".

**What becomes `unknown`:**

| In the file | The value says |
|---|---|
| `minSdk = maxOf(flutter.minSdkVersion, 26)`, or any value that isn't a string, a number or a name | `computed in Gradle code: ...` |
| the same key set twice | `set more than once (lines 12, 40)` |
| a key set inside an `if`, a loop, a lambda or `afterEvaluate { }` | `set conditionally ...` |
| a key set inside a scope function (also through `it` or `this`), a callback or a block such as `tasks.withType<...>().configureEach { }` that Appstein doesn't follow; or AGP's block form, `compileSdk { version = release(36) }`, `minSdk { ... }`, `targetSdk { ... }`; or an old setter such as `setNamespace("x")` | `set where Appstein doesn't follow (line N)` |
| the old forms: `minSdkVersion(21)`, `minSdkVersion = 21`, `setMinSdkVersion(21)` | `set with the old name ...` |
| a plugin declared with `alias(libs.plugins.x)`, a variable, or a version added with a `.version(...)` call chain | `declared with ...`, or `declared without a plain version` |
| signing set by a flavor, or release signing that comes from `defaultConfig` with something Appstein can't read | `release sets no signing config, and flavors set their own ...` |
| `jvmToolchain(17)` or `java { toolchain { } }` instead of `jvmTarget` | `set by jvmToolchain(...)`, `set by a Java toolchain` |
| a flavor or signing config created with a computed name, an `if`, a lambda or `by creating` | the whole list is `unknown`: `a flavor is declared in a way Appstein doesn't follow ...` |
| a Gradle file with an unclosed string, comment or bracket | every value that needs the file: `could not be read: ...`, with the line |

A flavor created by a call, such as `create("dev")` with no block, is listed. Only what its block sets plainly is recorded under it.

**Groovy build files** (`build.gradle`, the older form) **aren't read yet.** The values that need one are `unknown` with the reason "Groovy build files aren't read yet", and the manifests, the Gradle wrapper and `gradle.properties` are still read. Reading Groovy is a future item (spec §18 M3). When both `build.gradle` and `build.gradle.kts` exist, the reason is "both ... exist".

## Flutter's own values

A new Flutter app's `app/build.gradle.kts` doesn't contain `minSdk = 24`. It says `minSdk = flutter.minSdkVersion`, and Flutter's Gradle plugin gives `flutter` its numbers. Appstein resolves them the way Flutter does ([`_FlutterValues`](../../packages/appstein_engine/lib/src/packs/android/android_native.dart)):

- **`flutter.compileSdkVersion`, `flutter.minSdkVersion`, `flutter.targetSdkVersion` and `flutter.ndkVersion`** come from `toolchain.json`'s Android template (see [toolchain](toolchain.md)). That is read from the SDK's own `gradle_utils.dart`, and the value says `resolvedFrom: flutter`. When the SDK's file can't be read, it comes from Appstein's curated notes, and says `resolvedFrom: notes`. When neither has it, the value is `unknown`. In Flutter 3.47.5 these equal what `FlutterExtension.kt`, the file that defines `flutter.*` for Gradle, says: 36, 24, 36 and `28.2.13676358`.
- **`flutter.versionCode` and `flutter.versionName`** come from `pubspec.yaml`'s `version:`, by Flutter's rules:
  - the parts before and after the `+` are the name and the number;
  - for Android the number keeps only its digits and is at least 1;
  - a version that `pub_semver` can't parse counts as no version;
  - with no number, `FlutterPlugin.kt`'s default is 1, and with no valid version the name is `1.0`. The value then says `resolvedFrom: default`, with a `note` saying why;
  - when `pubspec.yaml` is missing or damaged, the value is `unknown`, never a default: Flutter's defaults apply only to a pubspec that was read.
- **Any other `flutter.something`** is `unknown`: it isn't a value Flutter's Gradle plugin defines.

**What `native.json` can't know.** These can change the real values, and none of them is in the project files Appstein reads:
- `flutter build --build-number` and `--build-name` override `version:` at build time;
- a `~/.gradle/gradle.properties` on the developer's machine can override a project's properties;
- a stale `flutter.versionCode` in `android/local.properties`, which Flutter writes and Appstein never reads (it holds machine paths).

So `versionCode` and `versionName` say what the project's files say. The build may differ.

## iOS files

**Two property-list readers, because Xcode writes two formats.**
- [`readXmlPlist`](../../packages/appstein_engine/lib/src/packs/ios/info_plist_reader.dart) reads `Info.plist`, which is XML. A binary property list, or XML that is broken, is `unknown` with the line, never a crash. As XML requires, `\r\n` and a lone `\r` become `\n` before reading, so a multi-line usage description is the same under any checkout.
- [`readPbxproj`](../../packages/appstein_engine/lib/src/packs/ios/pbxproj_reader.dart) reads `project.pbxproj`, which is in the old "OpenStep" format, curly braces and semicolons, not XML. Xcode can read a JSON project, but never writes one, so Appstein doesn't read it.

Both give the same [`PlistValue`](../../packages/appstein_engine/lib/src/packs/ios/plist_value.dart) tree, with each value's line, so every `at` is exact.

**The Runner target, and settings inherited from the project.** An Xcode project holds settings at two levels: the Runner target's configuration (`Debug`, `Profile`, `Release`), and the project's configuration of the same name. A setting the target doesn't set comes from the project. So for each setting Appstein looks in the target first. If it isn't there, it takes the project's, and adds the note `set at project level`. Xcode ranks the Runner configuration's own `.xcconfig` file (its `baseConfigurationReference`, such as `Flutter/Release.xcconfig`) above the project's settings, so when the configuration has one, the note says `set at project level; the target's .xcconfig file can override it`. If the value is in neither level, it is `unknown`: "may come from an .xcconfig file". A value with `$(...)` in it is kept as written, with the note `uses Xcode build variables`; the same note goes on `Info.plist` values with `$(...)`, such as the bundle id and the scene delegate. The golden's `deploymentTarget: 15.0` is `set at project level`, with the `.xcconfig` note. A development team's ID is never recorded, only whether one is set (`developmentTeamSet`); a team that isn't a single value is `unknown`.

**`Package.swift` exists on Windows too, but without the plugins.** `flutter pub get` writes `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift` on any OS, and Appstein reads it from the files, so a Windows developer gets `generatedPackage` too. When it isn't there, `absent` says why: "not generated yet: `flutter pub get` writes it", or "SwiftPM is off, so Flutter doesn't generate it". But only a Mac with Xcode 15 or later has SwiftPM in effect (`usesSwiftPackageManager` in Flutter's `xcode_project.dart`). On any other machine Flutter writes an empty placeholder (`generatePluginsSwiftPackage` with no plugins and no `FlutterFramework`, in `darwin_dependency_management.dart`), even when the app has iOS plugins. When SwiftPM is in use, Flutter always adds `FlutterFramework` (`swift_package_manager.dart`). So `plugins` is `found` (names only, `FlutterFramework` left out) only when the file depends on `FlutterFramework`; otherwise it is `unknown`: "written without Swift Package Manager in effect: Flutter lists the plugins here only on a Mac with Xcode 15 or later". `iosVersion` is read either way. The file also holds the plugins' paths, which are machine paths, and those are never read.

**There is usually no Podfile.** Flutter creates `ios/Podfile` only when a plugin needs CocoaPods, so a new app has none, and `podfile` is `absent` ("no ios/Podfile: Flutter creates one only when a plugin needs CocoaPods"). When there is one, `platform` is the version of its `platform :ios, '...'` line. The reader doesn't run Ruby, so a line it can't trust is `unknown` with the reason: a version written as a Ruby expression (`platform :ios, $iOSVersion`), an interpolated string (`"#{ver}"`), an `if` or `unless` modifier, a line inside an `if`, `unless`, `case`, `while`, `begin` or `do` block, such as `target 'Runner' do` (it only counts those openers against `end`; the reason is "set inside a Ruby block ..., which Appstein doesn't follow"), or more than one `platform :ios` line (CocoaPods uses the last, so the first isn't reported). A commented-out line doesn't count. `Podfile.lock` is not read; only whether it exists is recorded.

## SwiftPM, decided as Flutter decides

Whether SwiftPM is on changes which files Flutter generates and builds with, so an agent needs the right answer. [`swiftPackageManagerEnabled`](../../packages/appstein_engine/lib/src/packs/ios/swiftpm_setting.dart) follows `FlutterFeaturesConfig.isEnabled` in Flutter 3.47.5, in this order, and the first source that has a value wins:

1. `pubspec.yaml`: `flutter: config: enable-swift-package-manager: true` (`resolvedFrom: pubspec.yaml`);
2. Flutter's global settings, the file `flutter config` writes (`resolvedFrom: flutter config (global)`);
3. the environment variable `FLUTTER_SWIFT_PACKAGE_MANAGER` (`resolvedFrom: FLUTTER_SWIFT_PACKAGE_MANAGER`);
4. the default for the Flutter version (`resolvedFrom: default`).

**Flutter's comment is misleading.** `flutter_features.dart` says "environment variable > project manifest > global config". The code does not do that: `isEnabled` checks the project manifest, then the global config, and the environment variable only after them. Appstein copies the code, not the comment. The whole check is in [`swiftpm_setting.dart`](../../packages/appstein_engine/lib/src/packs/ios/swiftpm_setting.dart).

Details that follow from the code:
- **Only `true` turns the variable on.** Anything else is off, and an **empty value counts as set**, so `FLUTTER_SWIFT_PACKAGE_MANAGER=` is off, where an unset variable would fall through to the default. On Windows the variable's name ignores case. The value says the environment is the one `appstein sync` ran in: a build started elsewhere may not have it.
- **A value Flutter would stop on is `unknown`:** a non-boolean in `pubspec.yaml` or in the global config, or `flutter: config:` that isn't a map. A `pubspec.yaml` that exists but can't be read makes the whole decision `unknown`, because it decides first.
- **The default is on since stable 3.44.0**, on every channel (`note: on by default since Flutter 3.44`). An older stable is off. An older beta or master is `unknown`, because only the stable lines were checked.
- **`swiftPackageIntegrated`** is true exactly when `project.pbxproj` mentions `FlutterGeneratedPluginSwiftPackage`, which is Flutter's own test.

## No secrets, no machine paths

`native.json` is read by agents and may end up in logs, so it must never hold a secret or a path from the developer's machine. Where each rule is enforced:

| Rule | How |
|---|---|
| No `gradle.properties` secrets | only `android.useAndroidX`, `android.newDsl`, `android.builtInKotlin` and keys starting with `kotlin.` are read ([`androidGradleProperties`](../../packages/appstein_engine/lib/src/packs/android/android_native.dart)). The file may hold signing passwords |
| No keystore paths or passwords | `signingConfigs` lists names only; `releaseSigningConfig` is the name of a config, never its fields |
| No team ID | `developmentTeamSet` is true or false only |
| No machine paths from Xcode or SwiftPM | the plugins' names from `Package.swift` are kept, never their paths; `local.properties` is never read |
| No distribution URL | when `distributionUrl` isn't a `gradle-<version>-<bin or all>.zip`, the reason doesn't repeat it, because it may be a local path |
| Paths in `at` are relative | every `at` is relative to the project, with `/` |
| No error messages | an `error` section holds only the error's type; the message may hold a path, and is shown only in the sync output |

## How sync builds it

[`NativeSync`](../../packages/appstein_engine/lib/src/native/native_sync.dart) turns the packs' native extractors into `map/native.json`:

```text
KnowledgeSync.run
  |-- PlatformSync.build     sdk.json, toolchain.json
  |-- MapSync.build          the map (may run flutter pub get)
  |-- NativeSync.build       map/native.json, from the platform packs
  |-- renderDelta            delta.md
  `-- KnowledgeStore.locked  writeAll
```

- **A native extractor is a `NativeExtractor`** ([`native_extractor.dart`](../../packages/appstein_engine/lib/src/native/native_extractor.dart)): the name of its section and one method, `extract(NativeContext)`. The context holds the project folder, the Flutter version and channel, the host's environment variables, and Flutter's Android values. It has **no Dart analysis**, on purpose. A platform pack's `nativeExtractor` is how a pack reaches `NativeSync`; stack packs return null.
- **It runs after `MapSync`.** When the map needs packages, `flutter pub get` runs, and that rewrites the generated `Package.swift` that the `ios` pack reads. Running after means the file is the new one.
- **It is independent of the map.** When the map is skipped (the packages can't be fetched, or a lock file is broken), `native.json` is still written, because Gradle and Xcode files need no Dart analysis. A developer who is offline still gets the native facts. In that case `Package.swift` may not exist yet, and says so.
- **A pack that fails costs only its section.** `NativeSync` catches anything an extractor throws (`on Object`, as the map and the delta do). That section becomes `{"status": "error", "errorType": "<type>"}`, the other section is kept, and the sync does not fail. The whole error goes to the sync output only (see [cli](cli.md#appstein-sync)). Extractors are not supposed to throw for a project's own problems: a missing or damaged file is `absent` or `unknown`.
- **Two packs writing one section is a `StateError`:** a mistake in Appstein's pack list, which `appstein.yaml` can't cause (the config loader rejects a platform listed twice). `MapSync` has the same check for two extractors writing one map file.
- **No platform pack, no file.** With no native extractor, `NativeSync` returns no file.
- **`NativeReport`** says how each section went, in a few words: `read`, `absent: no ios/ folder`, or `internal error (StateError)`. `appstein sync` prints it as a `Native config:` line.

**Freshness.** `native.json`'s input hash covers:
- every file the extractors read: its bytes, a marker when it can't be read, or nothing when it is missing;
- for the `ios` pack, the global SwiftPM setting's value and the environment variable's, because they decide `enabled`;
- for the `android` pack, Flutter's Android values (the template's numbers and whether they came from the SDK or the notes);
- the Flutter version and channel, and each pack's id and version;
- Appstein's own version and the file format version.

So an edited `build.gradle.kts`, a changed `flutter config`, a new Flutter and a new pack all rewrite it. Files nobody reads (an `.xcconfig`) are not in the hash.

## Known limits

- **Values set only in `.xcconfig` files, or by Gradle code, are `unknown`.** Appstein never reads an `.xcconfig`, and never evaluates Gradle.
- **A project-level Xcode value may be overridden** by the Runner target's own `.xcconfig` file, which Appstein doesn't read. The note says so.
- **The plugin list needs a Mac.** `generatedPackage.plugins` is `unknown` on Windows and Linux (and on a Mac without Xcode 15 or later), because Flutter writes the file without the plugins there. The template's golden is made that way; the real-SDK test expects `found []` instead when the generated file has `FlutterFramework`.
- **Scope functions nested more than three deep** are read once, as inside the outer block, so a container (a flavor, a signing config) created that deep may be missed.
- **A Gradle key set through a variable** (`val dc = android.defaultConfig; dc.minSdk = 21`) isn't seen, so it can still read `absent`.
- **Podfile blocks are only counted**, not understood: Ruby that decides at run time is `unknown` only when it uses a block opener or a modifier the reader knows.
- **Build-time and machine-level changes are invisible.** `--build-number` and `--build-name`, a `~/.gradle/gradle.properties` override, and a stale `flutter.versionCode` in `local.properties` can change the real values. See [Flutter's own values](#flutters-own-values).
- **A flavor created by a call is listed**, but only what its own block sets plainly is recorded.
- **Groovy build files aren't read yet.** A future item (spec §18 M3).
- **SwiftPM from the environment** reflects the environment `appstein sync` ran in.

## Tests

- **Readers:** `packages/appstein_engine/test/packs/android/` has a test file per reader (`kts_reader_test.dart`, `properties_reader_test.dart`, `manifest_reader_test.dart`) and `android_native_test.dart` for the `android` section's values, including the cases in the `unknown` table above. `packages/appstein_engine/test/packs/ios/` has the same for the two property-list readers (`info_plist_reader_test.dart`, `pbxproj_reader_test.dart`), the `Package.swift` and Podfile readers (`ios_files_test.dart`), the SwiftPM decision (`swiftpm_setting_test.dart`) and the `ios` section (`ios_native_test.dart`). The shared file helper is tested in `packages/appstein_engine/test/native/native_files_test.dart`. The readers are also tried with `\r\n` line ends.
- **Sync:** `packages/appstein_engine/test/native/native_sync_test.dart` covers the extractor seam: a failing pack, two packs for one section, the input hash. `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart` checks that `native.json` is written, also when the map is skipped because `pub get` failed, left alone by an unchanged sync, and rewritten when the SwiftPM variable or the global setting changes.
- **The template app:** `packages/appstein_engine/test/fixtures/native/template_app/` holds the native files of a real Flutter 3.47.5 `flutter create`, each ending in `.fixture` (see [testing](testing.md#the-native-template-and-its-golden)). To remake it, from the repo root, so FVM uses the pinned Flutter, run `fvm flutter create --no-pub --platforms=android,ios --org dev.sample --project-name probe_app <a folder outside the repo>/probe_app`, then `fvm flutter pub get` there (which writes `Package.swift`). Copy the files listed in the plan's [Task 5, step 1](../superpowers/plans/2026-10-02-slice-1b4-native-config.md) with `.fixture` added. Never copy `local.properties`, and check that no copied file holds a machine path.
- **The golden:** `native_template_test.dart` runs `NativeSync` with both packs on the template app and compares the result, byte for byte, with `native.json.golden`.
- **The real SDK:** `packages/appstein_engine/test/integration/native_real_sdk_test.dart` (tagged `integration`) runs a real `flutter create` and a real sync, checks facts that hold on Flutter 3.44 and 3.47, and on 3.47.5 compares the whole file with the golden. It skips the golden when SwiftPM is set on that machine, since the golden holds the default. If a golden changes, the template or the code is wrong until proven otherwise (see [testing](testing.md#goldens)).
