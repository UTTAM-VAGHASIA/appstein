<!-- covers:
packages/appstein_engine/lib/src/sdk/**
packages/appstein_engine/lib/src/android/**
packages/appstein_protocol/lib/src/sdk_info.dart
-->

# Finding Flutter, the JDK and the Android SDK

Before Appstein can say anything about a project, it must know which Flutter SDK the project uses, and for Android, which JDK and Android SDK Flutter will build with. This page explains the three lookups. They live in `packages/appstein_engine/lib/src/sdk/` and `packages/appstein_engine/lib/src/android/`.

## Why the lookups copy Flutter's own

The JDK, Android SDK and settings-file lookups follow the rules of Flutter's own tool (`flutter_tools`, Flutter 3.47), in the same order, and their `///` comments name the Flutter function each one mirrors. The Flutter SDK lookup follows the tools a developer runs Flutter with: FVM, then `FLUTTER_ROOT`, then the PATH. **A different answer from Flutter's is a bug, even when ours looks more sensible.** The point of doctor is to describe the toolchain Flutter will really use. If Appstein picked a "better" JDK than Flutter does, doctor could call the machine healthy while every Android build failed. [doctor](doctor.md#a-rule-the-checks-follow) tells the slice 1a story behind this rule.

## The Flutter SDK

`SdkDetector.detect` in [`sdk_detector.dart`](../../packages/appstein_engine/lib/src/sdk/sdk_detector.dart) finds the SDK with `FlutterSdkLocator`, then reads its versions. It returns an `SdkDetection`: the facts and the location when it worked, or a problem and a fix hint when it didn't.

`FlutterSdkLocator.locate`, in [`flutter_sdk_locator.dart`](../../packages/appstein_engine/lib/src/sdk/flutter_sdk_locator.dart), tries three sources in order and records which one worked (`SdkSource`):

1. **The project's FVM pin.**
2. **The `FLUTTER_ROOT` environment variable.** It is used when it names an SDK folder, even when its version differs from the pin. The detector then reports the mismatch.
3. **`flutter` on PATH.** Its path is resolved through links, and the SDK is the folder two levels up. A snap, Homebrew or asdf shim doesn't resolve into an SDK folder, so it doesn't count.

A folder counts as an SDK when it has `bin/flutter` (`bin/flutter.bat` on Windows) and the framework's package folder, `<sdk>/packages/flutter`.

### FVM pins

`readFvmPin` in [`fvm_pin.dart`](../../packages/appstein_engine/lib/src/sdk/fvm_pin.dart) reads the pin:

- **Two file formats:** `.fvmrc` (FVM 3, the `flutter` key) or `.fvm/fvm_config.json` (FVM 2, the `flutterSdkVersion` key). In one folder, `.fvmrc` wins.
- **Parent folders too:** it looks in the project folder, then each parent up to the drive root, as FVM does. The nearest folder with a pin wins, so a project inside a monorepo uses the repo's pin.
- **An unreadable pin is an error,** not "no pin": the lookup stops with "Could not read the FVM pin".

Then the SDK for the pin, in `_locateFvm`:

1. **The `.fvm/flutter_sdk` link** in the folder that holds the pin, resolved to the real folder.
2. **FVM's cache:** `versions/<pin>` inside `FVM_CACHE_PATH`, or inside `~/fvm` when that variable isn't set.

**A stale link is skipped.** `.fvm/` is usually gitignored while the pin is committed, so after you pull a pin bump the link still points at the old version. When the link's SDK reports a version other than the pin, it is skipped and the cache is tried. The link is kept when its SDK can't be read yet (the detector then reports it as not set up), and when the pin names a channel such as `stable`, which can't be compared with a version.

### A pin FVM doesn't have

A pin states which version the project needs; FVM is only one way to install it. So when FVM has no SDK for the pin, the lookup goes on to `FLUTTER_ROOT` and PATH, and the location it returns carries the pin in `SdkLocation.unmetFvmPin`.

- **The version must equal the pin.** The detector compares them. A mismatch fails with "The project pins Flutter X with FVM, but FVM does not have it installed…" and the fix `fvm install X`.
- **A match is accepted.** `SdkInfo.fvmVersion` is set to the pin, just as when FVM provides the SDK, and the Flutter check adds a detail line saying a matching Flutter is used in FVM's place.
- **With no other SDK at all,** the lookup fails: the pinned version is not installed.

### Links and junctions

The FVM link and `flutter` on PATH are often symbolic links, or junctions on Windows. `resolveLinks` follows both to the real folder; see [running-tools](running-tools.md#resolvelinks).

## Versions

[`flutter_sdk_reader.dart`](../../packages/appstein_engine/lib/src/sdk/flutter_sdk_reader.dart):

- **`readSdkVersions` reads `bin/cache/flutter.version.json`** in the SDK: the Flutter version, the bundled Dart version and the channel. It is the file `flutter --version --machine` prints, so the answer is the same. Reading it takes milliseconds, while starting `flutter --version` takes seconds, and doctor would pay that on every run.
- **`SdkNotSetUpException`** means the SDK folder exists but Flutter has never run in it, so that file isn't there yet. FVM lists such versions as "Need setup". The fix hint is to run `flutter --version` once (`fvm flutter --version` for an FVM SDK).
- Unexpected contents are a `FormatException`, reported with the fix "Reinstall this Flutter version".

**The language version** comes from the project, not the SDK. `languageVersionFromPubspec` in [`language_version.dart`](../../packages/appstein_engine/lib/src/sdk/language_version.dart) takes the lower bound of `environment: sdk:` in `pubspec.yaml`, as `major.minor` (for example `3.9`), or null when there is none. It matters because new Dart syntax, such as dot shorthands, is allowed by the project's language version, not by the installed SDK ([spec §3](../superpowers/specs/2026-09-29-appstein-design.md#3-what-the-research-changed-key-facts)).

**The supported range** is in [`supported_versions.dart`](../../packages/appstein_engine/lib/src/sdk/supported_versions.dart):

| Constant | Value | Used for |
|---|---|---|
| `minSupportedFlutter` | 3.44.0 | Older is an error in the Flutter check |
| `newestKnownFlutterMinor` | 3.47 | A newer minor is info: it works, but version notes may be incomplete |
| `minimumXcodeMajor` | 26 | Older is an error in the Xcode check |

`appstein --version` prints the first two as the supported Flutter range.

**`SdkInfo`**, in [`sdk_info.dart`](../../packages/appstein_protocol/lib/src/sdk_info.dart), carries the result: the Flutter, Dart and language versions, the channel and the FVM pin. It lives in the protocol package because later slices share it: slice 1b will write it to `.appstein/platform/sdk.json` ([spec §6.2](../superpowers/specs/2026-09-29-appstein-design.md#62-the-appstein-folder)). Today it is only built in memory.

## Flutter's settings file

`flutter config` saves settings such as `jdk-dir`, `android-studio-dir` and `android-sdk` in a JSON file. `flutterSettingsPath` in [`flutter_settings.dart`](../../packages/appstein_engine/lib/src/android/flutter_settings.dart) finds it where Flutter does:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\.flutter_settings` |
| macOS, Linux | `~/.flutter_settings` if it exists; otherwise `$XDG_CONFIG_HOME/settings`, or `~/.config/flutter/settings` when `XDG_CONFIG_HOME` isn't set |

`readFlutterSettings` returns the settings as a map. A missing, unreadable or invalid file gives an empty map, as if nothing were configured. A byte order mark is stripped first.

## The JDK

`locateFlutterJava` in [`java_locator.dart`](../../packages/appstein_engine/lib/src/android/java_locator.dart) returns the JDK Flutter uses, from the first of these that gives one (`JavaSource`):

1. **`flutter config --jdk-dir`**, the `jdk-dir` setting. Any text counts, even empty text: Flutter then looks for `bin/java` relative to the folder it runs in, which fails. `flutter config --jdk-dir=""` removes the setting instead, and JSON `null` counts as unset. The Java check reports an empty value, or one that isn't text, as an error with the command to fix it.
2. **Android Studio's bundled JDK.**
3. **`JAVA_HOME`.**
4. **`java` on PATH.**

It returns a `JavaLookup`: `location`, the JDK, or null when none gives one, and `skipped`, the Android Studio installs passed over on the way. `skipped` is filled either way, so the Java check can explain a missing JDK too.

### Which Android Studio

This mirrors Flutter's `AndroidStudio.latestValid`:

- **When `android-studio-dir` is set, only that install counts.** On Windows and Linux its version comes from a matching install record; on macOS, from the app's `Info.plist`.
- **Otherwise, the installs Flutter knows about:**
  - **Windows and Linux: install records.** These are the `.home` files Android Studio writes into its settings folders: `~/.AndroidStudio*` and `~/.cache/Google/AndroidStudio*`, plus `%LOCALAPPDATA%\Google\AndroidStudio*` on Windows. Each names an install folder, and the settings folder's name gives the version. When several records name one install, the newest version is kept.
  - **Linux also:** `/opt/android-studio` and `~/android-studio`.
  - **Windows:** only the records, as in Flutter. The default install folder isn't searched.
  - **macOS:** only `Android Studio.app` in `/Applications` and `~/Applications`, with the version from its `Info.plist`.
- **Newest first:** known versions before unknown ones, newest version first. Flutter has no rule for equal versions; Appstein puts a release before a Preview.
- **The bundled JDK must run.** For each install in turn, the bundled JDK is `jbr` (Android Studio 2022 and newer, or an unknown version) or `jre` (older), under `Contents/` on macOS. The first install whose `java -version` succeeds is chosen.
- **Every install passed over is listed in `skipped`,** with the reason: no bundled JDK, a JDK that doesn't run, or a configured folder that doesn't exist. The Java check shows these lines whether or not it finds a JDK.
- **JetBrains Toolbox installs are not searched.**

**A configured `android-studio-dir` that doesn't exist is an error.** Flutter stops with a tool error in that case, whatever JDK it would otherwise use. So `JavaCheck`, in [`java_check.dart`](../../packages/appstein_engine/lib/src/doctor/checks/java_check.dart), checks the setting before it looks for a JDK at all, and reports an error with the command to fix or clear it. See [doctor](doctor.md).

**The version.** The locator runs `java -version` only for Android Studio JDKs, and keeps the output. For the other sources, the Java check runs it. `parseJavaMajor` reads the major version from that output: 21 from `version "21.0.2"`, 8 from the old `version "1.8.0_202"` style, or from an `openjdk 21` line. The Java check needs 17 or newer, the oldest JDK current Android Gradle Plugin versions accept.

## The Android SDK

`locateAndroidSdk` in [`android_sdk_locator.dart`](../../packages/appstein_engine/lib/src/android/android_sdk_locator.dart) mirrors Flutter's `locateAndroidSdk`:

1. **It takes the first *defined* of:** the `android-sdk` setting, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and the default folder (`%USERPROFILE%\AppData\Local\Android\sdk` on Windows, `~/Library/Android/sdk` on macOS, `~/Android/Sdk` on Linux). *Defined* matters: a variable that is set but wrong does not fall through to the next one, because Flutter's doesn't either. An empty variable is the exception: Appstein treats it as unset, while Flutter treats it as defined (see the known gaps below).
2. **It accepts that folder or its `sdk` subfolder,** whichever is an SDK.
3. **Otherwise it tries `aapt`, then `adb`, on PATH.** Every `aapt` in PATH order comes first, with the SDK three folders above it (`<sdk>/build-tools/<version>/aapt`), then every `adb`, with the SDK two folders above it (`<sdk>/platform-tools/adb`). Links are resolved first, and the first folder that is an SDK wins. A shim, such as a Scoop or Chocolatey `adb`, doesn't resolve into an SDK, so the next one is tried. `findAllExecutables` finds them all (see [running-tools](running-tools.md#findallexecutables)).

A folder is an Android SDK when it has a `licenses/` or a `platform-tools/` folder.

**More than one `adb`.** The Android SDK check collects the SDK's own `adb` and every `adb` on PATH, with links resolved. When they are not all the same file, it lists them in its details, as `flutter doctor -v` does, because two different `adb` programs fight over the connection to devices. The status doesn't change.

### Platforms and build-tools

The Android SDK check reports the platform and build-tools Flutter will use, found the way Flutter's `AndroidSdk.reinitialize` finds them. [`android_sdk_contents.dart`](../../packages/appstein_engine/lib/src/android/android_sdk_contents.dart) reads the SDK:

- **Folder names are read leniently, like Flutter's `Version.parse`.** A name counts when it starts with a number: `37.0.0-rc2` reads as 37.0.0, `36` as 36.0.0 and `36.1` as 36.1.0. Anything after the numbers, such as `-rc2`, is kept for display but ignored when comparing, so a preview is neither older nor newer than its release. Names like `latest` or `.DS_Store` are skipped. In `build-tools`, files count too, as in Flutter.
- **Each platform needs an API level.** `platforms/android-36` has level 36 from its name. Any other name, such as `android-37.0` or `android-36.1`, needs a `build.prop` file with a `ro.build.version.sdk=<level>` line. A platform without a level is ignored, and the check lists it.
- **The newest platform is the one with the highest level.** Among platforms of the same level, the name that sorts last wins: Flutter keeps the folder listing's order, which is alphabetical on NTFS and APFS, and takes the last. Appstein sorts the names itself, so the answer is the same on every file system.
- **The build-tools are paired with that platform:** the newest build-tools with the same major version as its level, or else the newest of all. On a tie, such as `37.0.0` and `37.0.0-rc2`, the name that sorts first wins. That is the release, which is what Flutter picks on NTFS and APFS.

So on a machine with platforms up to `android-37.0` (level 37) and build-tools `35.0.0`, `36.1.0` and `37.0.0-rc2`, doctor says `platform android-37.0, build-tools 37.0.0-rc2`, the words `flutter doctor -v` prints. The check then looks for `zipalign` in those build-tools and for `platform-tools`. With no build-tools, or no platform with a level, it reports an error, as Flutter does.

Flutter also reports an error when the platform or the build-tools are older than its Gradle plugin needs. Those minimums are facts about each Flutter version, so they arrive with the toolchain knowledge in slice 1b.2.

## Known gaps

The lookups don't copy every corner of Flutter yet. The list is in the slice 1a plan's "Carried to later slices" section, in [`2026-09-29-slice-1a-workspace-cli-doctor.md`](../superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md). For example:

- **macOS Android Studio discovery is narrower than Flutter's.** It doesn't search `/Applications` for other `Android Studio*.app` names or subfolders, and doesn't use Spotlight, so a Mac with only a Preview app could get a different JDK than Flutter.
- **A pin that names a channel** (`stable`) and that FVM doesn't have fails the version comparison with a confusing message.
- FVM's own `cachePath` setting isn't read, and an invalid `FLUTTER_ROOT` is skipped silently.
- **An empty `ANDROID_HOME`.** Flutter counts a variable that is set as defined, even when it is empty, and stops the search there. `HostEnvironment` treats an empty variable as unset everywhere, so Appstein goes on to `ANDROID_SDK_ROOT` and the default folder.
- **`where` looks in the current folder first.** On Windows, Flutter finds `aapt` and `adb` with `where`, which searches the current folder before the PATH. `findAllExecutables` searches only the PATH.
