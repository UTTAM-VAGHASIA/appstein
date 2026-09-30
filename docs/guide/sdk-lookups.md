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
2. **The `FLUTTER_ROOT` environment variable.** It is used when it names an SDK folder, even when its version differs from the pin. The detector then reports the mismatch. When it is set but isn't an SDK, it is skipped with a note that the Flutter check shows. Flutter's own launcher scripts set `FLUTTER_ROOT` from where they live, so a wrong value can't confuse Flutter; it could only confuse this lookup, which is why doctor names it.
3. **`flutter` on PATH.** Its path is resolved through links, and the SDK is the folder two levels up. A snap, Homebrew or asdf shim doesn't resolve into an SDK folder, so it doesn't count.

A folder counts as an SDK when it has `bin/flutter` (`bin/flutter.bat` on Windows) and the framework's package folder, `<sdk>/packages/flutter`.

**When nothing is found,** the failure names each source it tried and what it found there, such as ``No Flutter SDK found. Tried: no FVM pin in the project, FLUTTER_ROOT (not set), `flutter` on PATH (not found).`` Outside a project the FVM part is left out. With a pin FVM doesn't have, it names the pin (``the project's FVM pin (Flutter 3.46.0, from <file>, not installed)``), and the fix is the pin's `fvm install` command.

### FVM pins

`readFvmPin` in [`fvm_pin.dart`](../../packages/appstein_engine/lib/src/sdk/fvm_pin.dart) reads the pin:

- **Two file formats:** `.fvmrc` (FVM 3, the `flutter` key) or `.fvm/fvm_config.json` (FVM 2, the `flutterSdkVersion` key). In one folder, `.fvmrc` wins.
- **Parent folders too:** it looks in the project folder, then each parent up to the drive root, as FVM does. The nearest folder with a pin wins, so a project inside a monorepo uses the repo's pin.
- **An unreadable pin is an error,** not "no pin": the lookup stops with "Could not read the FVM pin", and the message gives the reason, in the OS's words when it gave any.

**What a pin names.** FVM accepts three kinds of value. `fvmPinChannel` and `fvmPinVersion` tell them apart:

| Pin | Meaning | An SDK meets it when |
|---|---|---|
| `stable`, `beta`, `dev`, `master`, `main` | A channel. FVM 4 counts `main` as a channel; FVM 3 treats it as a release name, but installs it in the same place | It is on that channel (`main` and `master` are one channel) |
| `3.24.0@beta` | A version on a channel | Its version is `3.24.0` |
| Anything else, such as `3.47.5` or a commit hash | A version, or a git reference | Its version is the whole value |

`describeFvmPin` puts a pin into words for messages ("Flutter 3.47.5", "the Flutter stable channel", "Flutter 3.24.0 on the beta channel"), and `fvmInstallHint` gives the fix: `fvm install <pin>`, and for a channel also `fvm use <channel>`.

Then the SDK for the pin, in `_locateFvm`:

1. **The `.fvm/flutter_sdk` link** in the folder that holds the pin, resolved to the real folder.
2. **FVM's cache:** `versions/<pin>` inside FVM's cache folder, so `versions/stable` for a channel and `versions/3.24.0@beta` for a version on a channel. `fvmCacheFolder` finds the cache folder as FVM does, highest first:
   1. `cachePath` in the pin file itself (a relative path is taken from the pin's folder);
   2. `FVM_CACHE_PATH`;
   3. `FVM_HOME`, FVM's older name for it;
   4. `cachePath` in FVM's global settings file, which `fvm config --cache-path` writes: `%APPDATA%\fvm\.fvmrc` on Windows, `~/Library/Application Support/fvm/.fvmrc` on macOS, and `$XDG_CONFIG_HOME/fvm/.fvmrc` (or `~/.config/fvm/.fvmrc`) on Linux;
   5. `fvm` in the home folder.

   A global settings file that can't be read or isn't valid JSON is ignored here. FVM itself stops with an error then, so the FVM check adds a line naming the file.

**A stale link is skipped.** `.fvm/` is usually gitignored while the pin is committed, so after you pull a pin bump the link still points at the old version. When the link's SDK reports a version other than the pin, it is skipped and the cache is tried. The link is kept when its SDK can't be read yet (the detector then reports it as not set up), and when the pin has no version to compare: a bare channel such as `stable`, or a git reference.

### A pin FVM doesn't have

A pin states which version the project needs; FVM is only one way to install it. So when FVM has no SDK for the pin, the lookup goes on to `FLUTTER_ROOT` and PATH, and the location it returns carries the pin in `SdkLocation.unmetFvmPin`.

- **The SDK must meet the pin.** The detector checks it, as in the table above: the version for a version pin, the channel (from `flutter.version.json`) for a channel pin. A mismatch fails with "The project pins Flutter X with FVM, but FVM does not have it installed…", or "…pins the Flutter stable channel…, and the Flutter found through PATH is on the beta channel", with the pin's `fvm install` fix.
- **A match is accepted.** `SdkInfo.fvmVersion` is set to the pin, just as when FVM provides the SDK, and the Flutter check adds a detail line saying a matching Flutter (or, for a channel pin, a Flutter on that channel) is used in FVM's place.
- **With no other SDK at all,** the lookup fails, naming the pin among the sources it tried.

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

- **When `android-studio-dir` is set, only that install counts.** On Windows and Linux its version comes from a matching install record. On macOS it comes from the app's `Info.plist`. Two exceptions, both as in Flutter. A JetBrains Toolbox launcher named there is dropped, and the search below runs as if nothing were set. And when the setting names the `Contents` folder inside an `.app` (`.../Android Studio.app/Contents`) rather than the `.app` itself, Flutter adds that bundle as an ordinary candidate, never matches the setting to it, and so uses the newest install. `skipped` then carries a note saying so, and that pointing the setting at the `.app` makes it the only one.
- **Otherwise, the installs Flutter knows about:**
  - **Windows and Linux: install records.** These are the `.home` files Android Studio writes into its settings folders: `~/.AndroidStudio*` and `~/.cache/Google/AndroidStudio*`, plus `%LOCALAPPDATA%\Google\AndroidStudio*` on Windows. Each names an install folder, and the settings folder's name gives the version. When several records name one install, the newest version is kept.
  - **Linux also:** `/opt/android-studio` and `~/android-studio`.
  - **Windows:** only the records, as in Flutter. The default install folder isn't searched.
  - **macOS,** as Flutter's `_allMacOS`, in this order:
    1. every `Android Studio*.app` bundle in `/Applications`, then in `~/Applications`, at any depth. The search never looks inside an `.app` bundle and doesn't follow links to folders. Names are matched case-sensitively, so `Android Studio Preview.app` counts and `android studio.app` doesn't. A renamed `AS.app` is found only by Spotlight, in the next step;
    2. the bundle named by an `android-studio-dir` that ends in `Contents` (see above), unless the scan already found it;
    3. every bundle Spotlight knows by Android Studio's bundle ID (`mdfind 'kMDItemCFBundleIdentifier="com.google.android.studio*"'`), unless an earlier step already found that exact path. As in Flutter, what `mdfind` printed is used whatever its exit code; only an `mdfind` that can't start adds nothing.

    Each bundle's `Contents/Info.plist` is read with `/usr/bin/plutil -convert xml1 -o - <plist>`, which also reads the binary plists most apps ship, or as plain text when `plutil` can't start. If `plutil` runs but fails, the plist counts as empty, as in Flutter: no version, and not a launcher. A bundle whose plist has the `JetBrainsToolboxApp` key is a JetBrains Toolbox launcher, not an install. Flutter skips it, and so does Appstein, with a `skipped` line saying so. The real Toolbox install is found only through Spotlight, so with Spotlight indexing off, a Toolbox-only Mac has no Android Studio JDK, in Flutter and in doctor alike. The version is the plist's `CFBundleShortVersionString`. A Preview's `EAP AI-242.21829.142.2422.12358220` becomes 2024.2.2, from the four digits `2422`, as in Flutter.

    `locateFlutterJava` takes the folders to search as `macAppFolders`, so the tests run this search in temporary folders on every OS.
- **Newest first:** known versions before unknown ones, newest version first. Equal versions keep the install found first, because Flutter only replaces its choice with a strictly newer one. Appstein reads folders in the order the file system lists them, as Flutter does. On Windows (NTFS) that is alphabetical; on macOS (APFS) and Linux (ext4) it is not, so when two folders tie, the winner depends on the file system, and it is the same one Flutter picks on that machine. Among installs of unknown version, the folder whose path sorts last comes first, Flutter's rule for them.
- **The bundled JDK must run.** For each install in turn, the bundled JDK is `jbr` (Android Studio 2022 and newer, or an unknown version) or `jre` (older), under `Contents/` on macOS. The first install whose `java -version` succeeds is chosen.
- **Every install passed over is listed in `skipped`,** with the reason: no bundled JDK, a JDK that doesn't run, a configured folder that doesn't exist, or a JetBrains Toolbox launcher on macOS. It also carries the note for an `android-studio-dir` that names a `Contents` folder. The Java check shows these lines whether or not it finds a JDK.
- **On Windows and Linux, JetBrains Toolbox installs are found only through the `.home` records Android Studio writes,** as in Flutter.

**A configured `android-studio-dir` that doesn't exist is an error.** Flutter stops with a tool error in that case, whatever JDK it would otherwise use. So `JavaCheck`, in [`java_check.dart`](../../packages/appstein_engine/lib/src/doctor/checks/java_check.dart), checks the setting before it looks for a JDK at all, and reports an error with the command to fix or clear it. See [doctor](doctor.md).

**The version.** The locator runs `java -version` only for Android Studio JDKs, and keeps the output. For the other sources, the Java check runs it. `parseJavaMajor` reads the major version from that output: 21 from `version "21.0.2"`, 8 from the old `version "1.8.0_202"` style, or from an `openjdk 21` line. The Java check needs 17 or newer, the oldest JDK current Android Gradle Plugin versions accept.

## The Android SDK

`locateAndroidSdk` in [`android_sdk_locator.dart`](../../packages/appstein_engine/lib/src/android/android_sdk_locator.dart) mirrors Flutter's `locateAndroidSdk`:

1. **It takes the first *defined* of:** the `android-sdk` setting, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and the default folder (`%USERPROFILE%\AppData\Local\Android\sdk` on Windows, `~/Library/Android/sdk` on macOS, `~/Android/Sdk` on Linux). *Defined* matters: a variable that is set but wrong does not fall through to the next one, because Flutter's doesn't either. An empty variable is the exception: Appstein treats it as unset, while Flutter treats it as defined (see "Where Appstein differs from Flutter" below).
2. **It accepts that folder or its `sdk` subfolder,** whichever is an SDK.
3. **Otherwise it tries `aapt`, then `adb`, on PATH.** Every `aapt` in PATH order comes first, with the SDK three folders above it (`<sdk>/build-tools/<version>/aapt`), then every `adb`, with the SDK two folders above it (`<sdk>/platform-tools/adb`). Links are resolved first, and the first folder that is an SDK wins. A shim, such as a Scoop or Chocolatey `adb`, doesn't resolve into an SDK, so the next one is tried. `findAllExecutables` finds them all (see [running-tools](running-tools.md#findallexecutables)).

A folder is an Android SDK when it has a `licenses/` or a `platform-tools/` folder.

**More than one `adb`.** The Android SDK check collects the SDK's own `adb` and every `adb` on PATH, with links resolved. When they are not all the same file, it lists them in its details, as `flutter doctor -v` does, because two different `adb` programs fight over the connection to devices. The status doesn't change.

### Platforms and build-tools

The Android SDK check reports the platform and build-tools Flutter will use, found the way Flutter's `AndroidSdk.reinitialize` finds them. [`android_sdk_contents.dart`](../../packages/appstein_engine/lib/src/android/android_sdk_contents.dart) reads the SDK:

- **Folder names are read leniently, like Flutter's `Version.parse`.** A name counts when it starts with a number: `37.0.0-rc2` reads as 37.0.0, `36` as 36.0.0 and `36.1` as 36.1.0. Anything after the numbers, such as `-rc2`, is kept for display but ignored when comparing, so a preview is neither older nor newer than its release. Names like `latest` or `.DS_Store` are skipped. In `build-tools`, files count too, as in Flutter.
- **Each platform needs an API level.** `platforms/android-36` has level 36 from its name. Any other name, such as `android-37.0` or `android-36.1`, needs a `build.prop` file with a `ro.build.version.sdk=<level>` line. A platform without a level is ignored, and the check lists it.
- **The newest platform is the one with the highest level.** Among platforms of the same level, the last one in the folder listing wins, as in Flutter. Appstein reads folders in the order the file system lists them, as Flutter does. On Windows (NTFS) that is alphabetical; on macOS (APFS) and Linux (ext4) it is not, so when two folders tie, the winner depends on the file system, and it is the same one Flutter picks on that machine.
- **The build-tools are paired with that platform:** the newest build-tools with the same major version as its level, or else the newest of all. On a tie, such as `37.0.0` and `37.0.0-rc2`, the first one in the folder listing wins, as in Flutter. On NTFS that is the release, because its name sorts first.

So on a machine with platforms up to `android-37.0` (level 37) and build-tools `35.0.0`, `36.1.0` and `37.0.0-rc2`, doctor says `platform android-37.0, build-tools 37.0.0-rc2`, the words `flutter doctor -v` prints. The check then looks for `zipalign` in those build-tools and for `platform-tools`. With no build-tools, or no platform with a level, it reports an error, as Flutter does.

Flutter also reports an error when the platform or the build-tools are older than its Gradle plugin needs. Those minimums are facts about each Flutter version, so they arrive with the toolchain knowledge in slice 1b.2.

## Where Appstein differs from Flutter

The lookups give Flutter's answer, and where Flutter does something surprising, the check's details explain it. A few differences are deliberate, or wait for a later slice:

- **An empty `ANDROID_HOME`.** Flutter counts a variable that is set as defined, even when it is empty, and stops the search there. `HostEnvironment` treats an empty variable as unset everywhere, so Appstein goes on to `ANDROID_SDK_ROOT` and the default folder. The same holds for `JAVA_HOME=""`: Flutter uses a relative `bin/java`, and Appstein falls through to `java` on PATH.
- **`where` looks in the current folder first.** On Windows, Flutter finds `aapt` and `adb` with `where`, which searches the current folder before the PATH. `findAllExecutables` searches only the PATH.
- **A configured Android Studio on Windows.** Flutter reads `android-studio-dir` only after it has listed `%LOCALAPPDATA%\Google`, and skips the setting when that folder is missing. That is a Flutter bug in a rare case, and Appstein doesn't copy it: it always uses the configured install, because the setting is the user's explicit choice.
- **A configured Android Studio that doesn't exist.** Flutter stops every command with a tool error. The Java check reports it as an error, and the other checks still run.
- **Minimum versions.** Flutter reports an error when the platform or the build-tools are older than its Gradle plugin needs. Those minimums change with each Flutter version, so they come with the toolchain knowledge in slice 1b.2.
- **A broken FVM settings file.** FVM stops with an error when its global settings file isn't valid JSON. Appstein's lookup ignores the file, and the FVM check names it.
- **Folder order is the file system's.** Where the answer depends on the order a folder is listed in (ties between Android Studio installs, platforms or build-tools), Appstein keeps that order, as Flutter does, so it gives Flutter's answer on the same machine. It is alphabetical on Windows (NTFS) but not on macOS (APFS) or Linux (ext4).
- **Toolchain facts Flutter also checks.** The Android SDK check doesn't yet report what Flutter's Android toolchain check also reports: a missing `cmdline-tools` component (an error in Flutter), an SDK with only `licenses`, an SDK path with spaces, a missing `android.jar`, or an `aapt` that can't run in the paired platform and build-tools. These are planned with slice 1b.2's toolchain facts.
- **The "Multiple adb binaries found" hint.** Flutter shows it only when the SDK is otherwise well formed. Appstein always lists conflicting `adb` programs.
- **An empty `FVM_CACHE_PATH` (or an empty global `cachePath`).** FVM uses it as a relative `versions` folder. Appstein treats it as unset.
- **FVM 4 fork pins.** Pins such as `fork/3.24.0`, and a forked `x@channel` (which FVM caches without `@channel`), aren't understood.
- **The Toolbox launcher key.** Appstein spots a JetBrains Toolbox launcher by the `JetBrainsToolboxApp` key anywhere in `Info.plist`. Flutter looks at the top-level dictionary only.
