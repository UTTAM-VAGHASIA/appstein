# Slice 1b.1: SDK Lookup Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `appstein doctor` give the same answers as `flutter doctor -v` on Windows, macOS and Linux, by closing the lookup gaps slice 1a deferred to 1b and the "stricter stale rule" slice 1a.1 deferred, before slice 1b.2 builds the knowledge layer on top.

**Why this slice exists:** slice 1a's plan ends with "Carried to later slices" (`docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md`, the "Slice 1b" list), and `docs/guide/sdk-lookups.md` lists the same items under "Known gaps". On the development machine today, doctor says `build-tools 36.1.0` while `flutter doctor -v` says `build-tools 37.0.0-rc2`. A Mac whose only Android Studio is a Preview app, or sits in a subfolder, can get a different JDK line than Flutter's. A project pinned to `stable` fails with a confusing message on a machine without FVM. Slice 1b.2 will write these facts into `.appstein/platform/`, so they must be right first.

**Architecture:**
- **Match Flutter, and explain it** (spec §5.3, §15). Where Flutter's behaviour is surprising (a preview build-tools beats a stable one; a Toolbox launcher is skipped; an empty `jdk-dir` breaks the JDK lookup), doctor gives Flutter's answer and says why in the result's details or fix hint.
- **Build-tools and platforms** move into a new file, `android/android_sdk_contents.dart`, which reads folder names with Flutter's lenient version rule and pairs the newest platform with its build-tools, as `AndroidSdk.reinitialize` does.
- **`findAllExecutables`** joins `findExecutable` in `host/executable_finder.dart`, for Flutter's "every `aapt`, then every `adb` on PATH" fallback and its "Multiple adb binaries found" hint.
- **The JDK lookup returns a `JavaLookup`** (the location, or none, plus the installs skipped), and on macOS it searches like Flutter's `_allMacOS`: a recursive scan, Spotlight through the `ProcessRunner`, `plutil`, the Toolbox exclusion and the EAP version rule. The folders to scan are a parameter, so the tests run on every OS.
- **FVM pins are classified** (channel, version on a channel, or version/git ref), FVM's cache folder is found in FVM's own order, and the Flutter SDK lookup records notes and names every source it tried.
- **A shared `fileErrorReason`** puts the OS's own words ("Access is denied.") into file errors.
- **The integration tests** run the `flutter` that `SdkDetector` finds for the repo, and add a platform/build-tools comparison.
- **The stale-page check** stops counting a page whose only change is inside generated sections.

**Tech Stack:** Dart 3.13.4 via Flutter 3.47.5 (FVM); `package:path`, `package:pub_semver` (both already dependencies), `package:test`. FVM 3.2.1 on the development machine (behaviour cross-checked with FVM 4.3.1's source).

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §5.3 (doctor), §15 (non-functional requirements), §19.4 (per-slice process), §19.6 (the developer guide and its checks). Flutter's behaviour is taken from the pinned SDK's own source, `C:\Users\<you>\fvm\versions\3.47.5\packages\flutter_tools\lib\src\` (`android/android_sdk.dart`, `android/android_studio.dart`, `android/java.dart`, `base/version.dart`).

## Global Constraints

- **Tooling:** run every Dart command through FVM (`fvm dart …`). The repo pins Flutter **3.47.5** in `.fvmrc`. The `dart` on your PATH may be an older SDK; never use it. Engine tests run from `packages/appstein_engine`; the repo tool tests run from the repo root (`fvm dart test test`).
- **Windows is first-class:** paths with spaces and non-ASCII characters must work. `tempDir()` (engine tests) and `tempFolder()`/`tempRepo()` (tool tests) already create folders named `appstein tëst …`; every file-system test uses them. Line endings can be CRLF anywhere a user edits a file.
- **Every public Dart member** gets a `///` doc comment (the `public_member_api_docs` lint). `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` stay clean after every task.
- **No new dependencies.** Anything new must already be in `pubspec.lock` and resolve on Flutter 3.44 (CI's `min-sdk` job runs the unit tests there). Language features up to Dart 3.12 only (the packages' `sdk: ^3.12.0`).
- **No `\u` escapes typed through the Edit or Write tools.** Those tools decode a backslash-u followed by four hex digits into the real character, so a byte order mark escape would land in the file as a raw BOM, which CI rejects ("No raw byte order marks in Dart files"). Where code needs the BOM, compare code units (`text.codeUnitAt(0) == 0xFEFF`). Existing escapes in files you don't rewrite stay as they are.
- **Commits:** only the controller (the main session) commits, with the owner's approval. Subagents never commit; each task ends by handing back with a suggested message. Commit messages end with the `Co-Authored-By` and `Claude-Session` trailers from the session.
- **Guide rules (spec §19.6):** a task that changes a covered file changes a covering page in the same task, in its hand-written text (after Task 8, a page whose only change is inside a generated section no longer counts), or the commit carries `Docs-Checked: <page> - <reason>`. After each task: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main` must print `The guide check passed.` No ```` ```dart ```` blocks in the guide.
- **Messages** are plain: short sentences, the exact command to run, no unexplained jargon. The exact strings in this plan are the contract; tests assert them.
- **Owner rulings are binding** (next section). If code and a ruling disagree in a way this plan doesn't cover, stop and ask; never re-decide.

## Owner rulings (binding, 2026-09-30)

The principle: doctor reports what Flutter will actually do on this machine. Where Flutter's behaviour is odd, Appstein matches it **and** explains it. It never silently "improves" on Flutter in a way that makes doctor disagree with `flutter doctor -v`.

The development machine (Windows): Android SDK at `C:\Users\<you>\AppData\Local\Android\Sdk`; platforms `android-33`, `android-34`, `android-35`, `android-36`, `android-36.1` (`build.prop` sdk=36), `android-37.0` (`build.prop` sdk=37); build-tools `35.0.0`, `36.1.0`, `37.0.0-rc2`. `flutter doctor -v` prints build-tools `37.0.0-rc2`. `.flutter_settings` has no `jdk-dir` or `android-studio-dir`. FVM 3.2.1; the global FVM config `%APPDATA%\fvm\.fvmrc` is `{}`.

| # | Ruling (condensed; the task holds the detail) | Task |
|---|---|---|
| R1 | Build-tools and platforms as `AndroidSdk.reinitialize`: lenient names (`^(\d+)(\.(\d+)(\.(\d+))?)?`, start-anchored, missing parts 0, original text kept, compare major/minor/patch only); platform level from `^android-(\d+)$`, else `ro.build.version.sdk=` in `build.prop`, else dropped; newest platform = highest level; build-tools = highest with major == level, else highest overall; ties prefer the name that sorts first. No platform with a level, or no build-tools: error with an `sdkmanager` hint. Summary `Android SDK: platform android-37.0, build-tools 37.0.0-rc2`. zipalign checked in the chosen build-tools. Flutter's minimum thresholds are parked (1b.2). | 1 |
| R2 | `findAllExecutables` (same PATH/PATHEXT rules, all matches, no current-folder search). Fallback after the one candidate: every `aapt` (three folders up), then every `adb` (two up); first valid SDK wins. More than one distinct resolved `adb` (the SDK's plus every PATH one): a details line, status unchanged. `ANDROID_HOME=""` semantics parked. | 2 |
| R3 | `locateFlutterJava` returns a non-null `JavaLookup {JavaLocation? location; List<String> skipped}`; `skipped` moves out of `JavaLocation`; JavaCheck shows `skipped` for the no-JDK error too. | 3 |
| R4 | A `jdk-dir` String (even `""`) is the JDK home, as in Flutter. JavaCheck: `""` is an error with the exact summary and fix below; a non-String value is the error "jdk-dir in <settings path> is not text"; JSON null = unset. | 3 |
| R5 | macOS Studio discovery as `_allMacOS`: recursive scan of `/Applications` then `~/Applications` (never inside `*.app`, no symlinked folders, `startsWith('Android Studio') && endsWith('.app')`), `mdfind` through `ProcessRunner` (not started / non-zero ignored; lines added unless identical), Info.plist through `/usr/bin/plutil -convert xml1 -o - <plist>` with a text fallback, Toolbox wrappers (`JetBrainsToolboxApp`) dropped, EAP version rule. Ties: equal known versions keep the first candidate. Configured Studio: keep using only it when set. Scan roots are a parameter; `fakeStudio` gains an `os` parameter; `_studioCandidates` becomes async and gets the runner. | 4 |
| R6 | Flutter's Windows early return (missing `%LOCALAPPDATA%\Google` drops the configured Studio) is a Flutter bug; Appstein doesn't copy it, and records it as a known difference. | 4, 6 |
| R7 | Classify FVM pins: channels `stable`, `beta`, `dev`, `master`, `main`; `x@channel` compares version `x`; anything else is a version or git ref. An unmet channel pin is met when the fallback SDK's channel equals it (`main` = `master`). Messages say "pins the Flutter <channel> channel", fix `fvm install <channel>` or `fvm use <channel>`. FvmCheck ok summary `Project pins the Flutter stable channel (.fvmrc)`. Fix the FlutterSdkLocator class doc. | 6 |
| R8 | FVM cache folder, highest first: the pin file's `cachePath` (relative to the pin's folder), `FVM_CACHE_PATH`, `FVM_HOME`, the global config's `cachePath`, `<home>/fvm`. An unreadable/invalid global config is ignored; FvmCheck adds a details line. `FvmPin` gains `cachePath`. | 6 |
| R9' | FLUTTER_ROOT set but not an SDK: skipped as today, with a note the Flutter check shows ("FLUTTER_ROOT is set to <path>, which is not a Flutter SDK, so it was ignored."), and named in the "No Flutter SDK found" failure. | 6 |
| R10 | "No Flutter SDK found. Tried: <the project's FVM pin \| no FVM pin in the project>, FLUTTER_ROOT (<not set \| set to X, not an SDK>), `flutter` on PATH (<not found \| found at X, not inside an SDK>)." The FVM part only with a project root. | 6 |
| R11 | `fileErrorReason(FileSystemException)` in `host/`, engine-internal, used by config_loader, project_check, fvm_pin, flutter_sdk_reader. ProjectCheck: a `ConfigException` with no `line` gets the fix "Make sure appstein.yaml is a readable UTF-8 text file." | 5 |
| R12 | Integration tests resolve the repo's SDK with `SdkDetector(env).detect(projectRoot: <repo root>)`, run its `bin/flutter(.bat)`, and call `Doctor.run(projectRoot: <repo root>)`. Detection failure fails under CI (`CI` set) and skips locally. A third test compares `flutter doctor -v`'s "Platform <p>, build-tools <b>" line with the Android SDK check's summary. Repo root = `readFvmPin(cwd).pinDirectory`. | 7 |
| R13 | A covering page counts as changed only when it differs from the merge-base copy after stripping generated bodies (`stripGeneratedBodies`; CRLF normalised; broken markers or a new page count as changed). `GitRepo.fileAt(rev, path)`. The filter runs in `guide_check.dart` before `checkStale`, whose signature is unchanged. Remove the docs-tooling Limits bullet. | 8 |
| Parked | `ANDROID_HOME=""`; Flutter's platform/build-tools minimums (1b.2 `toolchain.json`); `where` searching the current folder; the Windows early-return bug (documented). | "Carried to later slices" |

## Review Focus

1. **A platform folder with a dotted name and no `build.prop`**, such as a hand-copied `android-37.0` next to `android-36`. Expect doctor to say `platform android-36`, as Flutter does, and to name `android-37.0` as ignored. Pinned by Task 1's test "a dotted platform without build.prop is ignored, and named".
2. **A Toolbox-only Mac with Spotlight indexing off**: `/Applications/Android Studio.app` is a JetBrains Toolbox launcher and `mdfind` can't run. Expect JAVA_HOME (or no JDK), and a skipped line saying the launcher was passed over and why, never a JDK from inside the launcher. Pinned by Task 4's test "skips a JetBrains Toolbox launcher, and says why".
3. **FVM's global settings file is not valid JSON** (a hand edit gone wrong). Expect the SDK lookup to ignore it and use `~/fvm`, and the FVM check to add one line naming the file, never a crash. Pinned by Task 6's tests "a global settings file that is not JSON is ignored" and "a broken FVM settings file is named, since FVM itself will fail".
4. **A channel-qualified pin, `3.24.0@beta`.** Expect the stale-link check and the unmet-pin check to compare version `3.24.0`, the cache folder to be `versions/3.24.0@beta`, and messages to say "Flutter 3.24.0 on the beta channel". Pinned by Task 6's tests "a version@channel pin compares its version and has its own cache folder" and "a version@channel pin compares the version".
5. **A guide page whose only change is a regenerated section, saved with CRLF line endings on Windows.** Expect the stale-page check to still report the covered file. Pinned by Task 8's test "does not clear it with CRLF line endings either".

---

### Task 1: Platforms and build-tools, as Flutter pairs them (R1)

**Files:**
- Create: `packages/appstein_engine/lib/src/android/android_sdk_contents.dart`
- Create: `packages/appstein_engine/test/android/android_sdk_contents_test.dart`
- Modify: `packages/appstein_engine/lib/src/doctor/checks/android_sdk_check.dart` (whole file)
- Modify: `packages/appstein_engine/test/doctor/checks/android_sdk_check_test.dart` (whole file)
- Modify: `docs/guide/sdk-lookups.md` (line 127 and the "Known gaps" build-tools bullet), `docs/guide/doctor.md` ("A few behaviours the table doesn't show"; the generated table through `gen_docs`)

**Interfaces:**
- Produces (engine-internal, not exported from the barrel): `final class LenientVersion implements Comparable<LenientVersion>` with `static LenientVersion? tryParse(String text)`, fields `int major`, `int minor`, `int patch`, `String text`; `typedef AndroidPlatform = ({String name, int level})`; `final class AndroidSdkContents` with `List<LenientVersion> buildTools`, `List<AndroidPlatform> platforms`, `List<String> ignoredPlatforms`, getters `AndroidPlatform? latestPlatform` and `LenientVersion? buildToolsForLatest`; `AndroidSdkContents readAndroidSdkContents(String sdk)`.
- Produces: `AndroidSdkCheck` summaries `Android SDK: platform <name>, build-tools <text>` (ok) and `Android SDK: platform <name>, build-tools <text>, but with gaps` (warning). Task 7 compares the ok form with `flutter doctor -v`.

- [ ] **Step 1: Write the failing tests for the contents reader**

`packages/appstein_engine/test/android/android_sdk_contents_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/src/android/android_sdk_contents.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  group('LenientVersion reads folder names as Flutter does', () {
    for (final (text, parts) in [
      ('37.0.0-rc2', (37, 0, 0)),
      ('36', (36, 0, 0)),
      ('36.1', (36, 1, 0)),
      ('36.0.0.1', (36, 0, 0)),
      ('36abc', (36, 0, 0)),
      ('24.0.0-preview', (24, 0, 0)),
    ]) {
      test(text, () {
        final version = LenientVersion.tryParse(text)!;
        expect((version.major, version.minor, version.patch), parts);
        expect(version.text, text);
        expect('$version', text);
      });
    }

    test('a name that does not start with a number is not a version', () {
      for (final text in ['latest', '.DS_Store', 'android-36', '']) {
        expect(LenientVersion.tryParse(text), isNull, reason: text);
      }
    });

    test('a preview ties with its release; only numbers are compared', () {
      final rc = LenientVersion.tryParse('37.0.0-rc2')!;
      expect(rc.compareTo(LenientVersion.tryParse('37.0.0')!), 0);
      expect(LenientVersion.tryParse('36.1.0')!.compareTo(rc), lessThan(0));
    });
  });

  group('readAndroidSdkContents', () {
    late String sdk;

    setUp(() => sdk = p.join(tempDir().path, 'android sdk'));

    void folder(String path) =>
        Directory(p.joinAll([sdk, ...path.split('/')])).createSync(
          recursive: true,
        );

    void buildProp(String platform, String text) =>
        File(p.join(sdk, 'platforms', platform, 'build.prop'))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);

    test('reads levels from names and from build.prop, and lists the rest '
        'as ignored', () {
      folder('platforms/android-36');
      buildProp(
        'android-36.1',
        'ro.build.version.release=16\nro.build.version.sdk=36\n',
      );
      buildProp('android-37.0', 'ro.build.version.sdk=37\r\n');
      // Flutter's pattern allows no spaces around "=".
      buildProp('android-38.0', 'ro.build.version.sdk = 38\n');
      folder('platforms/android-TiramisuPrivacySandbox');
      final contents = readAndroidSdkContents(sdk);
      expect(contents.platforms, [
        (name: 'android-36', level: 36),
        (name: 'android-36.1', level: 36),
        (name: 'android-37.0', level: 37),
      ]);
      expect(contents.ignoredPlatforms, [
        'android-38.0',
        'android-TiramisuPrivacySandbox',
      ]);
    });

    test('among platforms of one level, the name that sorts last is the '
        'newest', () {
      folder('platforms/android-36');
      buildProp('android-36.1', 'ro.build.version.sdk=36\n');
      folder('build-tools/36.0.0');
      expect(
        readAndroidSdkContents(sdk).latestPlatform,
        (name: 'android-36.1', level: 36),
      );
    });

    test('build-tools entries are read by name, files too', () {
      folder('build-tools/35.0.0');
      folder('build-tools/latest');
      File(p.join(sdk, 'build-tools', '36.0.0'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      expect(readAndroidSdkContents(sdk).buildTools.map((v) => v.text), [
        '35.0.0',
        '36.0.0',
      ]);
    });

    test('a missing SDK folder reads as empty', () {
      final contents = readAndroidSdkContents(sdk);
      expect(contents.buildTools, isEmpty);
      expect(contents.platforms, isEmpty);
      expect(contents.latestPlatform, isNull);
      expect(contents.buildToolsForLatest, isNull);
    });
  });
}
```

- [ ] **Step 2: Rewrite the check's tests**

Replace all of `packages/appstein_engine/test/doctor/checks/android_sdk_check_test.dart` with:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late String sdk;

  setUp(() {
    sdk = p.join(tempDir().path, 'android sdk');
    Directory(p.join(sdk, 'platform-tools')).createSync(recursive: true);
  });

  const pairing =
      'Flutter pairs the newest platform with the newest build-tools of the '
      'same major version, previews included, or else with the newest '
      'build-tools.';

  void buildTools(String version, {bool zipalign = true}) {
    final dir = Directory(p.join(sdk, 'build-tools', version))
      ..createSync(recursive: true);
    if (zipalign) {
      File(
        p.join(dir.path, Platform.isWindows ? 'zipalign.exe' : 'zipalign'),
      ).writeAsStringSync('');
    }
  }

  /// A folder in `platforms/`, with a `build.prop` giving [sdkLevel] when it
  /// is set, written with [newline] line endings.
  void platform(String name, {int? sdkLevel, String newline = '\n'}) {
    final dir = Directory(p.join(sdk, 'platforms', name))
      ..createSync(recursive: true);
    if (sdkLevel != null) {
      File(p.join(dir.path, 'build.prop')).writeAsStringSync(
        [
          '# begin build properties',
          'ro.build.version.release=$sdkLevel',
          'ro.build.version.sdk=$sdkLevel',
          '',
        ].join(newline),
      );
    }
  }

  Future<CheckResult> run() => const AndroidSdkCheck().run(
    testContext(environment: fakeEnvironment({'ANDROID_HOME': sdk})),
  );

  // The development machine on 2026-09-30. `flutter doctor -v` printed
  // "Platform android-37.0, build-tools 37.0.0-rc2".
  test('regression: the platform and build-tools flutter doctor -v '
      'reports', () async {
    for (final name in ['android-33', 'android-34', 'android-35']) {
      platform(name);
    }
    platform('android-36');
    platform('android-36.1', sdkLevel: 36);
    platform('android-37.0', sdkLevel: 37, newline: '\r\n');
    buildTools('35.0.0');
    buildTools('36.1.0');
    buildTools('37.0.0-rc2');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(
      result.summary,
      'Android SDK: platform android-37.0, build-tools 37.0.0-rc2',
    );
    expect(result.details, ['Path: $sdk', pairing]);
  });

  test("the build-tools match the platform's major version, or else the "
      'newest', () async {
    platform('android-34');
    platform('android-36');
    buildTools('34.0.0');
    buildTools('35.0.0');
    expect(
      (await run()).summary,
      'Android SDK: platform android-36, build-tools 35.0.0',
    );
    buildTools('36.0.0');
    expect(
      (await run()).summary,
      'Android SDK: platform android-36, build-tools 36.0.0',
    );
  });

  test('a release and its preview tie, and the release wins, as on NTFS '
      'and APFS', () async {
    platform('android-37');
    buildTools('37.0.0-rc2');
    buildTools('37.0.0');
    expect(
      (await run()).summary,
      'Android SDK: platform android-37, build-tools 37.0.0',
    );
  });

  test('build-tools names that are not full versions count, as in '
      'Flutter', () async {
    platform('android-34');
    buildTools('33.0');
    buildTools('34');
    buildTools('latest');
    expect(
      (await run()).summary,
      'Android SDK: platform android-34, build-tools 34',
    );
  });

  // Review Focus 1.
  test('a dotted platform without build.prop is ignored, and named', () async {
    platform('android-36');
    platform('android-37.0');
    buildTools('36.0.0');
    buildTools('37.0.0');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(
      result.summary,
      'Android SDK: platform android-36, build-tools 36.0.0',
    );
    expect(
      result.details,
      contains(
        'Flutter ignores these platform folders, because it finds no API '
        'level in them: android-37.0.',
      ),
    );
  });

  test('a build-tools entry that is a file is still picked, with a '
      'warning', () async {
    platform('android-38');
    buildTools('37.0.0');
    File(p.join(sdk, 'build-tools', '38.0.0')).writeAsStringSync('');
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(
      result.summary,
      'Android SDK: platform android-38, build-tools 38.0.0, but with gaps',
    );
    expect(
      result.details,
      contains(
        'build-tools/38.0.0 is not a folder, but Flutter still picks it. '
        'Remove it, or reinstall build-tools 38.0.0.',
      ),
    );
  });

  test('warning when the paired build-tools has no zipalign', () async {
    platform('android-36');
    buildTools('36.1.0', zipalign: false);
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(
      result.details,
      contains(
        'build-tools 36.1.0 has no zipalign, so the 16 KB page-size check '
        'will be skipped.',
      ),
    );
  });

  test('error without build-tools', () async {
    platform('android-36');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'The Android SDK has no build-tools.');
    expect(
      result.fixHint,
      'Install build-tools with `sdkmanager "build-tools;<version>"`, or in '
      'Android Studio (SDK Manager, SDK Tools tab).',
    );
  });

  test('error without a platform that has an API level', () async {
    platform('android-37.0');
    buildTools('36.0.0');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(
      result.summary,
      "The Android SDK has no platforms, so Flutter can't build for Android.",
    );
    expect(
      result.fixHint,
      'Install a platform with `sdkmanager "platforms;android-<API level>"`, '
      'or in Android Studio (SDK Manager, SDK Platforms tab).',
    );
    expect(result.details.join('\n'), contains('android-37.0'));
  });

  test('error without any Android SDK', () async {
    final result = await const AndroidSdkCheck().run(
      testContext(environment: fakeEnvironment({})),
    );
    expect(result.status, CheckStatus.error);
    expect(result.fixHint, contains('ANDROID_HOME'));
  });
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/android/android_sdk_contents_test.dart test/doctor/checks/android_sdk_check_test.dart`
Expected: FAIL. The contents test doesn't compile (`android_sdk_contents.dart` doesn't exist). In the check test, the regression test fails with a summary of `Android SDK with build-tools 36.1.0`, and the platform tests fail on their summaries.

- [ ] **Step 4: Write `android_sdk_contents.dart`**

`packages/appstein_engine/lib/src/android/android_sdk_contents.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A version read from an Android SDK folder name the way Flutter's own
/// `Version.parse` reads it (`flutter_tools/lib/src/base/version.dart`,
/// Flutter 3.47).
///
/// Only the numbers at the start of the name count: `37.0.0-rc2` is 37.0.0,
/// `36` is 36.0.0 and `36.1` is 36.1.0. The whole name is kept in [text],
/// for display. Comparing looks at major, minor and patch only, so a preview
/// such as `37.0.0-rc2` ties with the release `37.0.0`.
final class LenientVersion implements Comparable<LenientVersion> {
  /// Creates a version from its parts and the [text] it was read from.
  const LenientVersion(this.major, this.minor, this.patch, this.text);

  /// Reads [text], or returns null when it doesn't start with a number.
  static LenientVersion? tryParse(String text) {
    final match = _leadingNumbers.firstMatch(text);
    if (match == null) return null;
    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[3] ?? '0');
    final patch = int.tryParse(match[5] ?? '0');
    if (major == null || minor == null || patch == null) return null;
    return LenientVersion(major, minor, patch, text);
  }

  static final _leadingNumbers = RegExp(r'^(\d+)(\.(\d+)(\.(\d+))?)?');

  /// The major version.
  final int major;

  /// The minor version, 0 when the name has none.
  final int minor;

  /// The patch version, 0 when the name has none.
  final int patch;

  /// The name it was read from, such as `37.0.0-rc2`.
  final String text;

  @override
  int compareTo(LenientVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => text;
}

/// A folder in an Android SDK's `platforms` folder, and the API level
/// Flutter reads for it.
typedef AndroidPlatform = ({String name, int level});

/// What Flutter reads from an Android SDK's `build-tools` and `platforms`
/// folders, and the pair it reports (`AndroidSdk.reinitialize` in
/// `flutter_tools/lib/src/android/android_sdk.dart`, Flutter 3.47).
final class AndroidSdkContents {
  /// Creates the contents.
  const AndroidSdkContents({
    required this.buildTools,
    required this.platforms,
    required this.ignoredPlatforms,
  });

  /// Every entry in `build-tools` whose name starts with a number, in name
  /// order. Files count too, as in Flutter.
  final List<LenientVersion> buildTools;

  /// Every platform folder with an API level, in name order.
  final List<AndroidPlatform> platforms;

  /// The platform folders Flutter ignores because it finds no API level in
  /// them, in name order.
  final List<String> ignoredPlatforms;

  /// The platform Flutter reports: the highest API level. Among platforms of
  /// one level, the name that sorts last: Flutter sorts a name-ordered
  /// listing by level, keeping ties in order, and takes the last. Null when
  /// there is none.
  AndroidPlatform? get latestPlatform {
    AndroidPlatform? latest;
    for (final platform in platforms) {
      if (latest == null || platform.level >= latest.level) latest = platform;
    }
    return latest;
  }

  /// The build-tools Flutter pairs with [latestPlatform]: the newest whose
  /// major version equals its API level, or else the newest of all. On a
  /// tie, such as `37.0.0` and `37.0.0-rc2`, the name that sorts first wins,
  /// as Flutter keeps the first one it lists. Null when there is no platform
  /// or no build-tools.
  LenientVersion? get buildToolsForLatest {
    final platform = latestPlatform;
    if (platform == null) return null;
    return _newest(buildTools.where((v) => v.major == platform.level)) ??
        _newest(buildTools);
  }

  static LenientVersion? _newest(Iterable<LenientVersion> versions) {
    LenientVersion? newest;
    for (final version in versions) {
      if (newest == null || version.compareTo(newest) > 0) newest = version;
    }
    return newest;
  }
}

/// Reads the `build-tools` and `platforms` folders of the Android SDK at
/// [sdk] as Flutter does. Never throws: a missing or unreadable folder
/// counts as empty.
AndroidSdkContents readAndroidSdkContents(String sdk) {
  final buildTools = <LenientVersion>[];
  for (final entry in _listByName(p.join(sdk, 'build-tools'))) {
    final version = LenientVersion.tryParse(p.basename(entry.path));
    if (version != null) buildTools.add(version);
  }
  final platforms = <AndroidPlatform>[];
  final ignored = <String>[];
  for (final entry in _listByName(p.join(sdk, 'platforms'))) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    final level = _platformLevel(entry.path, name);
    if (level == null) {
      ignored.add(name);
    } else {
      platforms.add((name: name, level: level));
    }
  }
  return AndroidSdkContents(
    buildTools: buildTools,
    platforms: platforms,
    ignoredPlatforms: ignored,
  );
}

final _numberedPlatform = RegExp(r'^android-([0-9]+)$');
final _sdkVersionLine = RegExp(r'^ro.build.version.sdk=([0-9]+)$');

/// The API level of the platform folder at [path], named [name]: from a
/// name like `android-36`, or else from the first `ro.build.version.sdk=`
/// line of its `build.prop`. Null when neither gives one.
int? _platformLevel(String path, String name) {
  final numbered = _numberedPlatform.firstMatch(name);
  if (numbered != null) return int.tryParse(numbered[1]!);
  final String text;
  try {
    text = File(p.join(path, 'build.prop')).readAsStringSync();
  } on FileSystemException {
    return null;
  }
  for (final line in const LineSplitter().convert(text)) {
    final match = _sdkVersionLine.firstMatch(line);
    if (match != null) return int.tryParse(match[1]!);
  }
  return null;
}

/// The entries of the folder at [path], sorted by name, or none when it
/// can't be listed. Links are followed, as in Flutter's listing. Flutter
/// uses the file system's own order, which is alphabetical on NTFS and
/// APFS; sorting makes the answer the same everywhere.
List<FileSystemEntity> _listByName(String path) {
  final dir = Directory(path);
  try {
    if (!dir.existsSync()) return const [];
    return dir.listSync()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  } on FileSystemException {
    return const [];
  }
}
```

- [ ] **Step 5: Rewrite `android_sdk_check.dart`**

Replace all of `packages/appstein_engine/lib/src/doctor/checks/android_sdk_check.dart` with:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../android/android_sdk_contents.dart';
import '../../android/android_sdk_locator.dart';
import '../../android/flutter_settings.dart';
import '../../host/host_environment.dart';
import '../doctor_check.dart';

/// Checks the Android SDK as Flutter reads it: the newest platform, the
/// build-tools Flutter pairs with it, `zipalign` in those build-tools for
/// the 16 KB page-size check, and `platform-tools`.
///
/// The summary names the platform and build-tools in the words
/// `flutter doctor -v` uses, so the two can be compared.
final class AndroidSdkCheck implements DoctorCheck {
  /// Creates the check.
  const AndroidSdkCheck();

  @override
  String get id => 'doctor.android_sdk';

  @override
  String get title => 'Android SDK';

  static const _pairing =
      'Flutter pairs the newest platform with the newest build-tools of the '
      'same major version, previews included, or else with the newest '
      'build-tools.';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final sdk = locateAndroidSdk(environment, readFlutterSettings(environment));
    if (sdk == null) {
      return const CheckResult.error(
        'No Android SDK found.',
        fixHint:
            'Install Android Studio or the command-line tools, then '
            'run `flutter config --android-sdk "<path>"` or set ANDROID_HOME.',
      );
    }
    final contents = readAndroidSdkContents(sdk);
    final details = [
      'Path: $sdk',
      if (contents.ignoredPlatforms.isNotEmpty)
        'Flutter ignores these platform folders, because it finds no API '
            'level in them: ${contents.ignoredPlatforms.join(', ')}.',
    ];
    if (contents.buildTools.isEmpty) {
      return CheckResult.error(
        'The Android SDK has no build-tools.',
        details: details,
        fixHint:
            'Install build-tools with `sdkmanager "build-tools;<version>"`, '
            'or in Android Studio (SDK Manager, SDK Tools tab).',
      );
    }
    final platform = contents.latestPlatform;
    final buildTools = contents.buildToolsForLatest;
    if (platform == null || buildTools == null) {
      return CheckResult.error(
        "The Android SDK has no platforms, so Flutter can't build for "
        'Android.',
        details: details,
        fixHint:
            'Install a platform with '
            '`sdkmanager "platforms;android-<API level>"`, or in Android '
            'Studio (SDK Manager, SDK Platforms tab).',
      );
    }
    details.add(_pairing);
    final pair = 'platform ${platform.name}, build-tools ${buildTools.text}';
    final problems = <String>[];
    final toolsDir = p.join(sdk, 'build-tools', buildTools.text);
    final zipalign = environment.os == HostOs.windows
        ? 'zipalign.exe'
        : 'zipalign';
    if (!Directory(toolsDir).existsSync()) {
      problems.add(
        'build-tools/${buildTools.text} is not a folder, but Flutter still '
        'picks it. Remove it, or reinstall build-tools ${buildTools.text}.',
      );
    } else if (!File(p.join(toolsDir, zipalign)).existsSync()) {
      problems.add(
        'build-tools ${buildTools.text} has no zipalign, so the '
        '16 KB page-size check will be skipped.',
      );
    }
    if (!Directory(p.join(sdk, 'platform-tools')).existsSync()) {
      problems.add(
        "platform-tools (adb) is missing, so apps can't be "
        'installed on devices.',
      );
    }
    if (problems.isNotEmpty) {
      return CheckResult.warning(
        'Android SDK: $pair, but with gaps',
        details: [...details, ...problems],
        fixHint:
            'Install the missing parts in Android Studio '
            '(SDK Manager, SDK Tools tab).',
      );
    }
    return CheckResult.ok('Android SDK: $pair', details: details);
  }
}
```

(`pub_semver` is no longer imported here; other engine files still use it, so `pubspec.yaml` doesn't change.)

- [ ] **Step 6: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test test/android/android_sdk_contents_test.dart test/doctor/checks/android_sdk_check_test.dart`
Expected: all pass.

- [ ] **Step 7: Check it on the development machine**

Run (repo root): `fvm dart run packages/appstein_cli/bin/appstein.dart doctor`
Expected: the Android SDK line reads `Android SDK: platform android-37.0, build-tools 37.0.0-rc2`, and `fvm flutter doctor -v` shows `Platform android-37.0, build-tools 37.0.0-rc2`. Record both lines in the hand-back report. (On another machine, the two must still agree.)

- [ ] **Step 8: Update the guide**

(a) In `docs/guide/sdk-lookups.md`, replace the line `The Android SDK check then looks inside: the newest build-tools (a preview only when there is no stable one), \`zipalign\` in it, and \`platform-tools\`.` with:

```markdown
### Platforms and build-tools

The Android SDK check reports the platform and build-tools Flutter will use, found the way Flutter's `AndroidSdk.reinitialize` finds them. [`android_sdk_contents.dart`](../../packages/appstein_engine/lib/src/android/android_sdk_contents.dart) reads the SDK:

- **Folder names are read leniently, like Flutter's `Version.parse`.** A name counts when it starts with a number: `37.0.0-rc2` reads as 37.0.0, `36` as 36.0.0 and `36.1` as 36.1.0. Anything after the numbers, such as `-rc2`, is kept for display but ignored when comparing, so a preview is neither older nor newer than its release. Names like `latest` or `.DS_Store` are skipped. In `build-tools`, files count too, as in Flutter.
- **Each platform needs an API level.** `platforms/android-36` has level 36 from its name. Any other name, such as `android-37.0` or `android-36.1`, needs a `build.prop` file with a `ro.build.version.sdk=<level>` line. A platform without a level is ignored, and the check lists it.
- **The newest platform is the one with the highest level.** Among platforms of the same level, the name that sorts last wins: Flutter keeps the folder listing's order, which is alphabetical on NTFS and APFS, and takes the last. Appstein sorts the names itself, so the answer is the same on every file system.
- **The build-tools are paired with that platform:** the newest build-tools with the same major version as its level, or else the newest of all. On a tie, such as `37.0.0` and `37.0.0-rc2`, the name that sorts first wins. That is the release, which is what Flutter picks on NTFS and APFS.

So on a machine with platforms up to `android-37.0` (level 37) and build-tools `35.0.0`, `36.1.0` and `37.0.0-rc2`, doctor says `platform android-37.0, build-tools 37.0.0-rc2`, the words `flutter doctor -v` prints. The check then looks for `zipalign` in those build-tools and for `platform-tools`. With no build-tools, or no platform with a level, it reports an error, as Flutter does.

Flutter also reports an error when the platform or the build-tools are older than its Gradle plugin needs. Those minimums are facts about each Flutter version, so they arrive with the toolchain knowledge in slice 1b.2.
```

(b) In the same file's `## Known gaps` list, delete the bullet that starts with `- **Build-tools:**`.

(c) In `docs/guide/doctor.md`, in the list after "A few behaviours the table doesn't show:", add after the `**The Java check names what Flutter passed over.**` bullet:

```markdown
- **The Android SDK check names the pair Flutter uses.** Its summary gives the newest platform and the build-tools Flutter pairs with it, previews included, in the words `flutter doctor -v` prints (`platform android-37.0, build-tools 37.0.0-rc2`). Platform folders Flutter ignores are listed in its details. See [sdk-lookups](sdk-lookups.md#platforms-and-build-tools).
```

(d) Run: `fvm dart run tool/gen_docs.dart`
Expected: `Updated docs/guide/doctor.md` (the check table's `doctor.android_sdk` row now reads "Checks the Android SDK as Flutter reads it: …").

(e) Run: `fvm dart run tool/check_guide.dart --since main`
Expected: `The guide check passed.`

- [ ] **Step 9: Format, analyze and run the engine tests**

Run: `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, then (in `packages/appstein_engine`) `fvm dart test`
Expected: no changes, `No issues found!`, all tests pass.

- [ ] **Step 10: Hand back to the controller to commit**

Suggested message: `feat(doctor): report the platform and build-tools Flutter pairs, as flutter doctor -v does`

---

### Task 2: `aapt` and every `adb` on PATH, and more than one `adb` (R2)

**Files:**
- Modify: `packages/appstein_engine/lib/src/host/executable_finder.dart` (whole file)
- Modify: `packages/appstein_engine/lib/src/android/android_sdk_locator.dart` (the doc comment and the fallback, lines 9-37)
- Modify: `packages/appstein_engine/lib/src/doctor/checks/android_sdk_check.dart` (imports, one line in `run`, a new static method)
- Modify: `packages/appstein_engine/test/host/executable_finder_test.dart`, `packages/appstein_engine/test/android/android_sdk_locator_test.dart`, `packages/appstein_engine/test/doctor/checks/android_sdk_check_test.dart`
- Modify: `docs/guide/running-tools.md`, `docs/guide/sdk-lookups.md`, `docs/guide/doctor.md`

**Interfaces:**
- Consumes: Task 1's `AndroidSdkCheck` (its `details` list and `run` structure).
- Produces: `List<String> findAllExecutables(String name, HostEnvironment environment)`, exported through the existing barrel export of `executable_finder.dart`. `findExecutable` keeps its signature and results.
- The details lines, exactly: `More than one adb was found. They can conflict, and devices may not be detected:`, then one `- <resolved path>` line per `adb`, the SDK's own first.

- [ ] **Step 1: Write the failing tests**

(a) Add to `packages/appstein_engine/test/host/executable_finder_test.dart`, at the end of `main()`:

```dart
  test('findAllExecutables lists every match, in PATH order', () {
    final first = tempDir();
    final second = tempDir();
    final a = fakeExecutable(first, 'mytool');
    final b = fakeExecutable(second, 'mytool');
    final separator = Platform.isWindows ? ';' : ':';
    final env = fakeEnvironment({
      'PATH': '${second.path}$separator${first.path}',
      'PATHEXT': defaultPathExt,
    });
    expect(findAllExecutables('mytool', env), [b, a]);
    expect(findExecutable('mytool', env), b);
  });

  test('findAllExecutables is empty when the tool is missing', () {
    final env = fakeEnvironment({
      'PATH': tempDir().path,
      'PATHEXT': defaultPathExt,
    });
    expect(findAllExecutables('mytool', env), isEmpty);
  });

  test('on Windows, findAllExecutables lists each PATHEXT match in a '
      'folder', () {
    final dir = tempDir();
    final cmd = File(p.join(dir.path, 'mytool.cmd'))
      ..writeAsStringSync('@echo off');
    final bat = File(p.join(dir.path, 'mytool.bat'))
      ..writeAsStringSync('@echo off');
    final env = fakeEnvironment({'PATH': dir.path, 'PATHEXT': '.BAT;.CMD'});
    expect(findAllExecutables('mytool', env), [bat.path, cmd.path]);
  }, testOn: 'windows');
```

(b) Add to `packages/appstein_engine/test/android/android_sdk_locator_test.dart`, at the end of `main()`:

```dart
  group('the PATH fallback, when the chosen folder is not an SDK', () {
    final separator = Platform.isWindows ? ';' : ':';

    test('every aapt on PATH, with the SDK three folders up', () {
      final root = tempDir();
      final elsewhere = Directory(p.join(root.path, 'other', 'bin', 'x'))
        ..createSync(recursive: true);
      fakeExecutable(elsewhere, 'aapt');
      final sdk = fakeAndroidSdk(p.join(root.path, 'real sdk'));
      final tools = Directory(p.join(sdk, 'build-tools', '36.0.0'))
        ..createSync(recursive: true);
      fakeExecutable(tools, 'aapt');
      final env = fakeEnvironment({
        'ANDROID_HOME': p.join(root.path, 'no sdk here'),
        'PATH': [elsewhere.path, tools.path].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(p.equals(locateAndroidSdk(env, {})!, resolveLinks(sdk)), isTrue);
    });

    test('then every adb on PATH, with the SDK two folders up, skipping '
        'shims', () {
      final root = tempDir();
      final shims = Directory(p.join(root.path, 'shims', 'bin'))
        ..createSync(recursive: true);
      fakeExecutable(shims, 'adb');
      final sdk = fakeAndroidSdk(p.join(root.path, 'real sdk'));
      fakeExecutable(Directory(p.join(sdk, 'platform-tools')), 'adb');
      final env = fakeEnvironment({
        'ANDROID_HOME': p.join(root.path, 'no sdk here'),
        'PATH': [shims.path, p.join(sdk, 'platform-tools')].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(p.equals(locateAndroidSdk(env, {})!, resolveLinks(sdk)), isTrue);
    });

    test('aapt comes before adb, whatever the PATH order', () {
      final root = tempDir();
      final viaAapt = fakeAndroidSdk(p.join(root.path, 'sdk a'));
      final tools = Directory(p.join(viaAapt, 'build-tools', '36.0.0'))
        ..createSync(recursive: true);
      fakeExecutable(tools, 'aapt');
      final viaAdb = fakeAndroidSdk(p.join(root.path, 'sdk b'));
      fakeExecutable(Directory(p.join(viaAdb, 'platform-tools')), 'adb');
      final env = fakeEnvironment({
        'PATH': [p.join(viaAdb, 'platform-tools'), tools.path].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(
        p.equals(locateAndroidSdk(env, {})!, resolveLinks(viaAapt)),
        isTrue,
      );
    });
  });
```

(c) Add to `packages/appstein_engine/test/doctor/checks/android_sdk_check_test.dart`, at the end of `main()`:

```dart
  group('more than one adb', () {
    /// Puts an `adb` program in the folder [dir]: `adb.exe` on Windows, an
    /// executable `adb` elsewhere. Returns its path.
    String placeAdb(String dir) {
      final file = File(p.join(dir, Platform.isWindows ? 'adb.exe' : 'adb'))
        ..createSync(recursive: true);
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
      return file.path;
    }

    Future<CheckResult> runWithPath(String path) => const AndroidSdkCheck()
        .run(
          testContext(
            environment: fakeEnvironment({
              'ANDROID_HOME': sdk,
              'PATH': path,
              'PATHEXT': defaultPathExt,
            }),
          ),
        );

    setUp(() {
      platform('android-36');
      buildTools('36.0.0');
    });

    test('lists every adb, and the status stays ok', () async {
      final sdkAdb = placeAdb(p.join(sdk, 'platform-tools'));
      final other = placeAdb(p.join(tempDir().path, 'other adb'));
      final result = await runWithPath(p.dirname(other));
      expect(result.status, CheckStatus.ok);
      expect(
        result.details,
        containsAllInOrder([
          'More than one adb was found. They can conflict, and devices may '
              'not be detected:',
          '- ${resolveLinks(sdkAdb)}',
          '- ${resolveLinks(other)}',
        ]),
      );
    });

    test("says nothing when the adb on PATH is the SDK's own", () async {
      placeAdb(p.join(sdk, 'platform-tools'));
      final result = await runWithPath(p.join(sdk, 'platform-tools'));
      expect(result.details.where((line) => line.contains('adb')), isEmpty);
    });
  });
```

- [ ] **Step 2: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/host/executable_finder_test.dart test/android/android_sdk_locator_test.dart test/doctor/checks/android_sdk_check_test.dart`
Expected: FAIL to compile (`findAllExecutables` isn't defined).

- [ ] **Step 3: Add `findAllExecutables`**

Replace all of `packages/appstein_engine/lib/src/host/executable_finder.dart` with:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'host_environment.dart';

/// Finds the command [name] on the PATH of [environment], the way a shell
/// would, and returns its full path, or null when it isn't installed.
///
/// On Windows it tries each PATHEXT extension in order (`.COM;.EXE;.BAT;.CMD`
/// by default). Elsewhere, the file must have an executable bit.
String? findExecutable(String name, HostEnvironment environment) =>
    _matches(name, environment).firstOrNull;

/// Every match for the command [name] on the PATH of [environment], in the
/// order a shell tries them: PATH order, and on Windows PATHEXT order within
/// one folder. The first is what [findExecutable] returns.
///
/// Flutter lists matches like this, with `where` on Windows and `which -a`
/// elsewhere, to find `aapt` and `adb`. Unlike `where`, this never looks in
/// the current folder first.
List<String> findAllExecutables(String name, HostEnvironment environment) =>
    _matches(name, environment).toList();

Iterable<String> _matches(String name, HostEnvironment environment) sync* {
  final windows = environment.os == HostOs.windows;
  final extensions = windows
      ? (environment.variable('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
            .split(';')
            .where((e) => e.isNotEmpty)
            .map((e) => e.toLowerCase())
            .toList()
      : const [''];
  final hasExtension =
      windows && extensions.contains(p.extension(name).toLowerCase());
  for (final dir in environment.pathEntries) {
    for (final extension in hasExtension ? const [''] : extensions) {
      final candidate = p.join(dir, '$name$extension');
      final file = File(candidate);
      if (!file.existsSync()) continue;
      if (!windows && (file.statSync().mode & 0x49) == 0) continue;
      yield candidate;
    }
  }
}
```

- [ ] **Step 4: Use it in the locator**

In `packages/appstein_engine/lib/src/android/android_sdk_locator.dart`, replace the doc comment and the `adb` block (from `/// Finds the Android SDK the way Flutter does` through the end of `locateAndroidSdk`) with:

```dart
/// Finds the Android SDK the way Flutter does (`locateAndroidSdk` in
/// `flutter_tools/lib/src/android/android_sdk.dart`, Flutter 3.47).
///
/// The first *defined* of `flutter config --android-sdk`, ANDROID_HOME,
/// ANDROID_SDK_ROOT and the default folder is used (or its `sdk`
/// subfolder). An empty variable counts as unset here, unlike in Flutter.
/// When that isn't a valid SDK, every `aapt` on PATH is tried, with the SDK
/// three folders above it (`build-tools/<version>/aapt`), then every `adb`,
/// with the SDK two folders above it (`platform-tools/adb`). Links are
/// resolved first. A folder is an SDK when it has `licenses/` or
/// `platform-tools/`.
String? locateAndroidSdk(
  HostEnvironment environment,
  Map<String, Object?> settings,
) {
  final configured = settings['android-sdk'];
  final candidate = configured is String
      ? configured
      : environment.variable('ANDROID_HOME') ??
            environment.variable('ANDROID_SDK_ROOT') ??
            _defaultAndroidSdk(environment);
  if (candidate != null) {
    if (_isAndroidSdk(candidate)) return candidate;
    final nested = p.join(candidate, 'sdk');
    if (_isAndroidSdk(nested)) return nested;
  }
  for (final aapt in findAllExecutables('aapt', environment)) {
    final root = p.dirname(p.dirname(p.dirname(resolveLinks(aapt))));
    if (_isAndroidSdk(root)) return root;
  }
  for (final adb in findAllExecutables('adb', environment)) {
    final root = p.dirname(p.dirname(resolveLinks(adb)));
    if (_isAndroidSdk(root)) return root;
  }
  return null;
}
```

- [ ] **Step 5: List more than one `adb` in the check**

In `packages/appstein_engine/lib/src/doctor/checks/android_sdk_check.dart`:

1. Add these imports, in order with the others:

```dart
import '../../host/executable_finder.dart';
import '../../host/file_links.dart';
```

2. After the `platform-tools` `if` block (just before `if (problems.isNotEmpty) {`), add:

```dart
    details.addAll(_adbConflicts(sdk, environment));
```

3. Add this method after `run`:

```dart
  /// Every distinct `adb`, as detail lines, when there is more than one:
  /// the SDK's own (`cmdline-tools` first, then `platform-tools`, as in
  /// Flutter's `getPlatformToolsPath`) and each one on PATH, with links
  /// resolved. Flutter shows the same list as its "Multiple adb binaries
  /// found" hint. Empty when there is one or none.
  static List<String> _adbConflicts(String sdk, HostEnvironment environment) {
    final name = environment.os == HostOs.windows ? 'adb.exe' : 'adb';
    final found = <String>{};
    for (final folder in ['cmdline-tools', 'platform-tools']) {
      final adb = p.join(sdk, folder, name);
      if (File(adb).existsSync()) {
        found.add(resolveLinks(adb));
        break;
      }
    }
    for (final adb in findAllExecutables('adb', environment)) {
      found.add(resolveLinks(adb));
    }
    if (found.length < 2) return const [];
    return [
      'More than one adb was found. They can conflict, and devices may not '
          'be detected:',
      for (final adb in found) '- $adb',
    ];
  }
```

- [ ] **Step 6: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test test/host/executable_finder_test.dart test/android/android_sdk_locator_test.dart test/doctor/checks/android_sdk_check_test.dart`
Expected: all pass.

- [ ] **Step 7: Update the guide**

(a) In `docs/guide/running-tools.md`, after the `## \`findExecutable\`` section's two bullets, add:

```markdown
### `findAllExecutables`

`findAllExecutables` returns every match instead of the first, in the order a shell tries them: PATH order, and on Windows the `PATHEXT` order inside one folder. Its first entry is what `findExecutable` returns. The Android SDK lookup uses it, because Flutter tries every `aapt` and every `adb` on the PATH, not only the first (see [sdk-lookups](sdk-lookups.md#the-android-sdk)).

Flutter lists them with `where` on Windows, which also looks in the current folder before the PATH. `findAllExecutables` doesn't, for the same reason `pathEntries` drops empty entries: a tool is never "found" just because it sits in the folder you ran Appstein from.
```

(b) In `docs/guide/sdk-lookups.md`, `## The Android SDK`:
- At the end of item 1, replace `because Flutter's doesn't either.` with `because Flutter's doesn't either. An empty variable is the exception: Appstein treats it as unset, while Flutter treats it as defined (see the known gaps below).`
- Replace item 3 with:

```markdown
3. **Otherwise it tries `aapt`, then `adb`, on PATH.** Every `aapt` in PATH order comes first, with the SDK three folders above it (`<sdk>/build-tools/<version>/aapt`), then every `adb`, with the SDK two folders above it (`<sdk>/platform-tools/adb`). Links are resolved first, and the first folder that is an SDK wins. A shim, such as a Scoop or Chocolatey `adb`, doesn't resolve into an SDK, so the next one is tried. `findAllExecutables` finds them all (see [running-tools](running-tools.md#findallexecutables)).
```

- After the sentence `A folder is an Android SDK when it has a \`licenses/\` or a \`platform-tools/\` folder.`, add:

```markdown
**More than one `adb`.** The Android SDK check collects the SDK's own `adb` and every `adb` on PATH, with links resolved. When they are not all the same file, it lists them in its details, as `flutter doctor -v` does, because two different `adb` programs fight over the connection to devices. The status doesn't change.
```

- In `## Known gaps`, add at the end of the list:

```markdown
- **An empty `ANDROID_HOME`.** Flutter counts a variable that is set as defined, even when it is empty, and stops the search there. `HostEnvironment` treats an empty variable as unset everywhere, so Appstein goes on to `ANDROID_SDK_ROOT` and the default folder.
- **`where` looks in the current folder first.** On Windows, Flutter finds `aapt` and `adb` with `where`, which searches the current folder before the PATH. `findAllExecutables` searches only the PATH.
```

(c) In `docs/guide/doctor.md`, append to the bullet `**The Android SDK check names the pair Flutter uses.**` (added in Task 1): ` When more than one \`adb\` is found (the SDK's own and others on the PATH), it lists them all, as \`flutter doctor -v\` does, without changing the status.`

(d) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.`

- [ ] **Step 8: Format, analyze and run the engine tests**

Run: `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, then (in `packages/appstein_engine`) `fvm dart test`
Expected: clean; all pass.

- [ ] **Step 9: Hand back to the controller to commit**

Suggested message: `feat(android): try every aapt and adb on PATH, and list conflicting adb programs`

---

### Task 3: `JavaLookup`, and an empty or non-text `jdk-dir` (R3, R4)

**Files:**
- Modify: `packages/appstein_engine/lib/src/android/java_locator.dart` (lines 29-139: `JavaLocation`, a new `JavaLookup`, `locateFlutterJava`)
- Modify: `packages/appstein_engine/lib/src/doctor/checks/java_check.dart` (`run`)
- Modify: `packages/appstein_engine/test/android/java_locator_test.dart` (whole file)
- Modify: `packages/appstein_engine/test/doctor/checks/java_check_test.dart` (new tests)
- Modify: `docs/guide/sdk-lookups.md`, `docs/guide/doctor.md`

**Interfaces:**
- Produces (exported, an API change): `final class JavaLookup { const JavaLookup({JavaLocation? location, List<String> skipped = const []}); final JavaLocation? location; final List<String> skipped; }`. `Future<JavaLookup> locateFlutterJava(HostEnvironment environment, Map<String, Object?> settings, ProcessRunner runner)`. `JavaLocation` loses `skipped`.
- The JavaCheck messages, exactly:
  - empty `jdk-dir`: summary `Flutter's jdk-dir setting is empty, so Flutter can't find a JDK.`, details `['Flutter treats the empty value as a JDK folder, and looks for bin/java relative to the folder it runs in.']`;
  - non-text `jdk-dir`: summary `jdk-dir in <settings path> is not text.`, details `['Flutter stops with an error when it reads this setting.']`;
  - both fix hints: ``Run `flutter config --jdk-dir="<path to a JDK 17+>"`, or `flutter config --jdk-dir=""` to remove the setting.``
  - no JDK: summary unchanged, `No JDK found. Android builds need JDK 17 or newer.`, with `details` = the lookup's `skipped`.
- Task 4 extends `locateFlutterJava` with a named `macAppFolders` parameter.

- [ ] **Step 1: Rewrite the locator's tests for the new return type, with the new cases**

Replace all of `packages/appstein_engine/test/android/java_locator_test.dart` with:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_android.dart';
import '../support/fake_process_runner.dart';
import '../support/temp.dart';

void main() {
  late FakeProcessRunner runner;

  setUp(() => runner = FakeProcessRunner());

  String javaIn(String home, [HostOs? os]) => p.join(
    home,
    'bin',
    (os ?? HostOs.current) == HostOs.windows ? 'java.exe' : 'java',
  );

  const java21 = RunResult(
    exitCode: 0,
    stderr: 'openjdk version "21.0.6" 2025-01-21',
  );
  const brokenJava = RunResult(
    exitCode: 1,
    stderr: "Error: could not open `jvm.cfg'",
  );

  /// An Android Studio folder whose bundled JDK runs.
  String workingStudio(Directory parent, [String name = 'Android Studio']) {
    final studio = fakeStudio(parent, name: name);
    runner.when(javaIn(studioJdkHome(studio)), ['-version'], java21);
    return studio;
  }

  /// An Android Studio folder whose bundled JDK exits with an error.
  String brokenStudio(Directory parent, [String name = 'Broken Studio']) {
    final studio = fakeStudio(parent, name: name);
    runner.when(javaIn(studioJdkHome(studio)), ['-version'], brokenJava);
    return studio;
  }

  String skippedNote(String studio) =>
      'Android Studio at $studio has a JDK that does not run; '
      'Flutter skips it.';

  /// Variables that make [home] the user's home folder.
  Map<String, String> homeVars(String home) =>
      Platform.isWindows ? {'USERPROFILE': home} : {'HOME': home};

  /// The JDK location alone, for tests that don't look at skipped installs.
  Future<JavaLocation?> locate(
    HostEnvironment environment,
    Map<String, Object?> settings,
  ) async => (await locateFlutterJava(environment, settings, runner)).location;

  test('flutter config --jdk-dir wins', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': 'configured',
    });
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, 'configured');
    expect(runner.calls, isEmpty);
  });

  test('an empty jdk-dir still counts, as in Flutter', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': '',
    });
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, '');
    expect(location.javaBinary, javaIn(''));
  });

  test('a jdk-dir of JSON null counts as unset', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': null,
    });
    expect(location!.source, JavaSource.javaHome);
  }, skip: studioInstalledReason());

  test("Android Studio's JDK comes before JAVA_HOME", () async {
    final studio = workingStudio(tempDir());
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'android-studio-dir': studio,
    });
    expect(location!.source, JavaSource.androidStudio);
    expect(location.home, studioJdkHome(studio));
    expect(location.versionOutput, contains('21.0.6'));
  });

  test('then JAVA_HOME, then java on PATH', () async {
    expect(
      (await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {}))!.source,
      JavaSource.javaHome,
    );
    final bin = tempDir();
    fakeExecutable(bin, 'java');
    final onPath = await locate(
      fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
      {},
    );
    expect(onPath!.source, JavaSource.path);
  }, skip: studioInstalledReason());

  test('finds no JDK when there is none', () async {
    final lookup = await locateFlutterJava(fakeEnvironment({}), {}, runner);
    expect(lookup.location, isNull);
    expect(lookup.skipped, isEmpty);
  }, skip: studioInstalledReason());

  test('no JDK: the Studio passed over is still reported', () async {
    final studio = brokenStudio(tempDir());
    final lookup = await locateFlutterJava(fakeEnvironment({}), {
      'android-studio-dir': studio,
    }, runner);
    expect(lookup.location, isNull);
    expect(lookup.skipped, [skippedNote(studio)]);
  });

  test('parses the major version from java -version output', () {
    expect(parseJavaMajor('openjdk version "21.0.2" 2024-01-16'), 21);
    expect(parseJavaMajor('java version "1.8.0_202"'), 8);
    expect(parseJavaMajor('openjdk version "17" 2021-09-14'), 17);
    expect(parseJavaMajor('openjdk 21.0.1 2023-10-17'), 21);
    expect(parseJavaMajor('garbage'), isNull);
  });

  test(
    'Windows: finds Studio through the LOCALAPPDATA Google AndroidStudio .home',
    () async {
      final root = tempDir();
      final studio = workingStudio(root);
      final localAppData = p.join(root.path, 'local');
      final record = Directory(
        p.join(localAppData, 'Google', 'AndroidStudio2025.1'),
      )..createSync(recursive: true);
      File(p.join(record.path, '.home')).writeAsStringSync('$studio\r\n');
      final location = await locate(
        fakeEnvironment({'LOCALAPPDATA': localAppData}),
        {},
      );
      expect(location!.source, JavaSource.androidStudio);
      expect(location.home, studioJdkHome(studio));
    },
    testOn: 'windows',
  );

  test(
    'Linux: finds Studio through ~/.cache/Google/AndroidStudio*/.home',
    () async {
      final root = tempDir();
      final studio = workingStudio(root);
      final home = p.join(root.path, 'home');
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.1',
        studio,
      );
      final location = await locate(fakeEnvironment({'HOME': home}), {});
      expect(location!.source, JavaSource.androidStudio);
      expect(location.home, studioJdkHome(studio));
    },
    testOn: 'linux',
  );

  test('an unusable .home file is ignored', () async {
    final root = tempDir();
    final home = p.join(root.path, 'home');
    writeStudioRecord(
      p.join(home, '.cache', 'Google'),
      'AndroidStudio2025.1',
      'no such folder',
    );
    final location = await locate(
      fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
      {},
    );
    expect(location!.source, JavaSource.javaHome);
  }, skip: studioInstalledReason());

  group('choosing among Android Studio installs, as Flutter does', () {
    // The development machine on 2026-09-30: old and Preview records point to a
    // Studio whose JBR is broken; newer records point to a working one.
    // `flutter doctor -v` uses the working one.
    test(
      'regression: the newest Studio whose JDK runs, not the Preview record',
      () async {
        final root = tempDir();
        final broken = brokenStudio(root, 'Android Studio');
        final working = workingStudio(root, 'Android Studio1');
        final localAppData = p.join(root.path, 'local');
        final google = p.join(localAppData, 'Google');
        for (final folder in [
          'AndroidStudio2024.1',
          'AndroidStudio2024.2',
          'AndroidStudio2024.3',
          'AndroidStudioPreview2024.2',
        ]) {
          writeStudioRecord(google, folder, broken);
        }
        for (final folder in [
          'AndroidStudio2025.3.2',
          'AndroidStudio2025.3.4',
        ]) {
          writeStudioRecord(google, folder, working);
        }
        final location = await locate(
          fakeEnvironment({'LOCALAPPDATA': localAppData, 'JAVA_HOME': 'jh'}),
          {},
        );
        expect(location!.source, JavaSource.androidStudio);
        expect(location.home, studioJdkHome(working));
      },
      testOn: 'windows',
    );

    test(
      'a Studio whose java fails is skipped, even when it is the newest',
      () async {
        final root = tempDir();
        final home = p.join(root.path, 'home');
        final google = p.join(home, '.cache', 'Google');
        final broken = brokenStudio(root);
        final working = workingStudio(root);
        writeStudioRecord(google, 'AndroidStudio2025.3.4', broken);
        writeStudioRecord(google, 'AndroidStudio2024.3', working);
        final lookup = await locateFlutterJava(
          fakeEnvironment(homeVars(home)),
          {},
          runner,
        );
        expect(lookup.location!.home, studioJdkHome(working));
        expect(lookup.skipped, [skippedNote(broken)]);
      },
      testOn: '!mac-os',
      skip: studioInstalledReason(),
    );

    test(
      'JAVA_HOME is next when no Studio JDK runs',
      () async {
        final root = tempDir();
        final home = p.join(root.path, 'home');
        final broken = brokenStudio(root);
        writeStudioRecord(
          p.join(home, '.cache', 'Google'),
          'AndroidStudio2025.3.4',
          broken,
        );
        final lookup = await locateFlutterJava(
          fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
          {},
          runner,
        );
        expect(lookup.location!.source, JavaSource.javaHome);
        expect(lookup.skipped, [skippedNote(broken)]);
      },
      testOn: '!mac-os',
      skip: studioInstalledReason(),
    );

    test('newest version first; a Preview of the same version comes after '
        'the release', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final google = p.join(home, '.cache', 'Google');
      final records = {
        'AndroidStudio2024.3': workingStudio(root, 'Studio A'),
        'AndroidStudio2025.3.2': workingStudio(root, 'Studio B'),
        'AndroidStudioPreview2025.3.4': workingStudio(root, 'Studio C'),
        'AndroidStudio2025.3.4': workingStudio(root, 'Studio D'),
      };
      records.forEach((folder, studio) {
        writeStudioRecord(google, folder, studio);
      });
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, studioJdkHome(records['AndroidStudio2025.3.4']!));
    }, testOn: '!mac-os');

    test('if android-studio-dir is set, only that install counts', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final configured = brokenStudio(root);
      final newer = workingStudio(root);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.3.4',
        newer,
      );
      final lookup = await locateFlutterJava(
        fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
        {'android-studio-dir': configured},
        runner,
      );
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [skippedNote(configured)]);
    });

    test('a Studio older than 2022 has its JDK in jre', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final studio = p.join(root.path, 'Old Studio');
      final jre = p.join(studio, 'jre');
      File(javaIn(jre)).createSync(recursive: true);
      runner.when(javaIn(jre), ['-version'], java21);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2021.3',
        studio,
      );
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, jre);
    }, testOn: '!mac-os');

    test(
      'Windows: an install with no .home record is not used, as in Flutter',
      () async {
        final programFiles = tempDir();
        workingStudio(Directory(p.join(programFiles.path, 'Android')));
        final location = await locate(
          fakeEnvironment({'ProgramFiles': programFiles.path, 'JAVA_HOME': 'jh'}),
          {},
        );
        expect(location!.source, JavaSource.javaHome);
      },
      testOn: 'windows',
    );
  });
}
```

- [ ] **Step 2: Add the JavaCheck tests**

In `packages/appstein_engine/test/doctor/checks/java_check_test.dart`:

1. Add after the `javaVersion` helper:

```dart
  const fixJdkDir =
      'Run `flutter config --jdk-dir="<path to a JDK 17+>"`, or '
      '`flutter config --jdk-dir=""` to remove the setting.';
```

2. Add at the end of `main()`:

```dart
  test('error when there is no JDK, still naming the Studio Flutter '
      'skipped', () async {
    final studio = fakeStudio(tempDir());
    runner.when(javaIn(studioJdkHome(studio)), [
      '-version',
    ], const RunResult(exitCode: 1, stderr: 'Error: broken'));
    final result = await run(settings({'android-studio-dir': studio}));
    expect(result.status, CheckStatus.error);
    expect(
      result.summary,
      'No JDK found. Android builds need JDK 17 or newer.',
    );
    expect(result.details, [
      'Android Studio at $studio has a JDK that does not run; '
          'Flutter skips it.',
    ]);
  });

  test("error for an empty jdk-dir, which Flutter can't use", () async {
    runner.when(javaIn('jdk 21'), ['-version'], javaVersion('21.0.2'));
    final result = await run(settings({'jdk-dir': ''}, {'JAVA_HOME': 'jdk 21'}));
    expect(result.status, CheckStatus.error);
    expect(
      result.summary,
      "Flutter's jdk-dir setting is empty, so Flutter can't find a JDK.",
    );
    expect(result.details, [
      'Flutter treats the empty value as a JDK folder, and looks for '
          'bin/java relative to the folder it runs in.',
    ]);
    expect(result.fixHint, fixJdkDir);
  });

  test('error for a jdk-dir that is not text', () async {
    final file = File(p.join(settingsDir.path, '.flutter_settings'))
      ..writeAsStringSync('{"jdk-dir": 17}');
    final result = await run({
      if (Platform.isWindows)
        'APPDATA': settingsDir.path
      else
        'HOME': settingsDir.path,
    });
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'jdk-dir in ${file.path} is not text.');
    expect(result.details, [
      'Flutter stops with an error when it reads this setting.',
    ]);
    expect(result.fixHint, fixJdkDir);
  });

  test('a jdk-dir of null counts as unset', () async {
    File(
      p.join(settingsDir.path, '.flutter_settings'),
    ).writeAsStringSync('{"jdk-dir": null}');
    runner.when(javaIn('jdk 21'), ['-version'], javaVersion('21.0.2'));
    final result = await run({
      if (Platform.isWindows)
        'APPDATA': settingsDir.path
      else
        'HOME': settingsDir.path,
      'JAVA_HOME': 'jdk 21',
    });
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('JAVA_HOME'));
  }, skip: studioInstalledReason());
```

- [ ] **Step 3: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/android/java_locator_test.dart test/doctor/checks/java_check_test.dart`
Expected: FAIL to compile (`JavaLookup` isn't defined; `locateFlutterJava` returns `JavaLocation?`).

- [ ] **Step 4: Return a `JavaLookup`**

In `packages/appstein_engine/lib/src/android/java_locator.dart`, replace everything from `/// The JDK Flutter would use.` through the end of `locateFlutterJava` (lines 29-139) with:

```dart
/// The JDK Flutter would use.
final class JavaLocation {
  /// Creates a location.
  const JavaLocation({
    required this.javaBinary,
    required this.source,
    this.home,
    this.versionOutput,
  });

  /// The `java` executable.
  final String javaBinary;

  /// Where it came from.
  final JavaSource source;

  /// The JDK folder, when known.
  final String? home;

  /// What `java -version` printed, when the lookup already ran it, so callers
  /// need not run it again. Null when the lookup did not run it.
  final String? versionOutput;
}

/// The result of looking for the JDK Flutter uses: the JDK, when there is
/// one, and the Android Studio installs passed over on the way.
final class JavaLookup {
  /// Creates a result.
  const JavaLookup({this.location, this.skipped = const []});

  /// The JDK Flutter would use, or null when it finds none.
  final JavaLocation? location;

  /// Why Flutter passed over Android Studio installs, one line each, in the
  /// order they were tried. It is filled whether or not a JDK was found, so
  /// a missing JDK can be explained too.
  final List<String> skipped;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`, whenever it is text, even empty text, as
///    in Flutter (an empty home gives a relative `bin/java` that won't run);
/// 2. the JDK bundled with Android Studio;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// A `jdk-dir` that is JSON null counts as unset. Any other non-text value
/// is skipped here too; `JavaCheck` reports it, because Flutter stops with
/// an error on it.
///
/// Android Studio is chosen as Flutter's `AndroidStudio.latestValid` chooses
/// it:
/// - when the `android-studio-dir` setting is set, only that install counts;
/// - otherwise the installs Flutter knows about are tried newest version
///   first. They are the ones named by Android Studio's install records (the
///   `.home` files it writes), plus `/opt/android-studio` and
///   `~/android-studio` on Linux and `Android Studio.app` in `/Applications`
///   and `~/Applications` on macOS.
///
/// An install counts only if its bundled `java -version`, run with [runner],
/// succeeds. The installs passed over are listed in [JavaLookup.skipped].
/// JetBrains Toolbox installs are not searched.
Future<JavaLookup> locateFlutterJava(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner,
) async {
  final configured = settings['jdk-dir'];
  if (configured is String) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(configured, environment),
        source: JavaSource.flutterConfig,
        home: configured,
      ),
    );
  }
  final skipped = <String>[];
  for (final studio in _studioCandidates(environment, settings)) {
    if (!Directory(studio.path).existsSync()) {
      skipped.add(
        '`android-studio-dir` points to ${studio.path}, which does not exist.',
      );
      continue;
    }
    final home = _studioJdkHome(studio, environment);
    final java = _javaIn(home, environment);
    if (!File(java).existsSync()) {
      skipped.add(
        'Android Studio at ${studio.path} has no bundled JDK; '
        'Flutter skips it.',
      );
      continue;
    }
    final result = await runner.run(java, ['-version']);
    if (result.ok) {
      return JavaLookup(
        location: JavaLocation(
          javaBinary: java,
          source: JavaSource.androidStudio,
          home: home,
          versionOutput: '${result.stderr}\n${result.stdout}',
        ),
        skipped: skipped,
      );
    }
    skipped.add(
      'Android Studio at ${studio.path} has a JDK that does not run; '
      'Flutter skips it.',
    );
  }
  final javaHome = environment.variable('JAVA_HOME');
  if (javaHome != null) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(javaHome, environment),
        source: JavaSource.javaHome,
        home: javaHome,
      ),
      skipped: skipped,
    );
  }
  final onPath = findExecutable('java', environment);
  return JavaLookup(
    location: onPath == null
        ? null
        : JavaLocation(javaBinary: onPath, source: JavaSource.path),
    skipped: skipped,
  );
}
```

- [ ] **Step 5: Update `JavaCheck.run`**

In `packages/appstein_engine/lib/src/doctor/checks/java_check.dart`, replace everything from `final java = await locateFlutterJava(environment, settings, context.runner);` through `final found = ['Path: ${java.home ?? java.javaBinary}', ...java.skipped];` with:

```dart
    // Flutter uses any text in jdk-dir as the JDK folder, and stops with an
    // error on anything else (`_findJavaHome` in `java.dart`).
    final jdkDir = settings['jdk-dir'];
    if (jdkDir != null && jdkDir is! String) {
      return CheckResult.error(
        'jdk-dir in ${flutterSettingsPath(environment)} is not text.',
        details: const [
          'Flutter stops with an error when it reads this setting.',
        ],
        fixHint: _fixJdkDir,
      );
    }
    if (jdkDir == '') {
      return const CheckResult.error(
        "Flutter's jdk-dir setting is empty, so Flutter can't find a JDK.",
        details: [
          'Flutter treats the empty value as a JDK folder, and looks for '
              'bin/java relative to the folder it runs in.',
        ],
        fixHint: _fixJdkDir,
      );
    }
    final lookup = await locateFlutterJava(
      environment,
      settings,
      context.runner,
    );
    final java = lookup.location;
    const pointFlutter =
        'Point Flutter at a working JDK $minimumMajor or '
        'newer: `flutter config --jdk-dir "<path to the JDK>"`.';
    if (java == null) {
      return CheckResult.error(
        'No JDK found. Android builds need JDK $minimumMajor or newer.',
        details: lookup.skipped,
        fixHint:
            'Install JDK $minimumMajor or newer, then set JAVA_HOME or '
            'run `flutter config --jdk-dir "<path>"`.',
      );
    }
    final where = '${java.source.label} (${java.home ?? java.javaBinary})';
    final found = ['Path: ${java.home ?? java.javaBinary}', ...lookup.skipped];
```

and add this constant after `static const minimumMajor = 17;`:

```dart
  /// The fix for a `jdk-dir` setting Flutter can't use.
  static const _fixJdkDir =
      'Run `flutter config --jdk-dir="<path to a JDK $minimumMajor+>"`, or '
      '`flutter config --jdk-dir=""` to remove the setting.';
```

(`flutterSettingsPath` comes from `../../android/flutter_settings.dart`, which the file already imports.)

- [ ] **Step 6: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test test/android/java_locator_test.dart test/doctor/checks/java_check_test.dart`
Expected: all pass (the macOS-only paths keep today's behaviour until Task 4).

- [ ] **Step 7: Update the guide**

(a) In `docs/guide/sdk-lookups.md`, `## The JDK`:
- Replace item 1 (`1. **\`flutter config --jdk-dir\`**, the \`jdk-dir\` setting.`) with:

```markdown
1. **`flutter config --jdk-dir`**, the `jdk-dir` setting. Any text counts, even empty text: Flutter then looks for `bin/java` relative to the folder it runs in, which fails. `flutter config --jdk-dir=""` removes the setting instead, and JSON `null` counts as unset. The Java check reports an empty value, or one that isn't text, as an error with the command to fix it.
```

- Replace `It returns null when none gives a JDK.` with:

```markdown
It returns a `JavaLookup`: `location`, the JDK, or null when none gives one, and `skipped`, the Android Studio installs passed over on the way. `skipped` is filled either way, so the Java check can explain a missing JDK too.
```

- Replace the bullet `- **Every install passed over is listed in \`skipped\`,** with the reason: no bundled JDK, a JDK that doesn't run, or a configured folder that doesn't exist. The Java check shows these lines.` with:

```markdown
- **Every install passed over is listed in `skipped`,** with the reason: no bundled JDK, a JDK that doesn't run, or a configured folder that doesn't exist. The Java check shows these lines whether or not it finds a JDK.
```

(b) In `docs/guide/doctor.md`, replace the bullet that starts `- **The Java check names what Flutter passed over.**` with:

```markdown
- **The Java check names what Flutter passed over.** Whether or not a JDK is found, each Android Studio install Flutter would skip gets a detail line saying why. An empty `jdk-dir` setting, or one that isn't text, is an error with the exact `flutter config` command to fix it, because Flutter can't use it. The check also compares the JDK with JAVA_HOME: another JDK of the same major version is info, a different version is a warning, because Gradle run outside Flutter uses JAVA_HOME. See [sdk-lookups](sdk-lookups.md#the-jdk).
```

(c) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.`

- [ ] **Step 8: Format, analyze and run the engine tests**

Run: `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, then (in `packages/appstein_engine`) `fvm dart test`
Expected: clean; all pass.

- [ ] **Step 9: Hand back to the controller to commit**

Suggested message: `feat(java): return skipped Studios with every JDK lookup, and report an empty or non-text jdk-dir`

---

### Task 4: macOS Android Studio discovery, as Flutter's `_allMacOS` (R5, R6)

**Files:**
- Modify: `packages/appstein_engine/lib/src/android/java_locator.dart` (whole file)
- Modify: `packages/appstein_engine/test/support/fake_android.dart` (whole file), `packages/appstein_engine/test/support/temp.dart` (the `fakeEnvironment` doc comment)
- Modify: `packages/appstein_engine/test/android/java_locator_test.dart` (one test renamed, two new tests, a new group)
- Modify: `docs/guide/sdk-lookups.md`, `docs/guide/testing.md`

**Interfaces:**
- Consumes: Task 3's `JavaLookup` and `locateFlutterJava`.
- Produces: `Future<JavaLookup> locateFlutterJava(HostEnvironment environment, Map<String, Object?> settings, ProcessRunner runner, {List<String>? macAppFolders})`. `macAppFolders` defaults to `['/Applications', '<home>/Applications']` and is used only when `environment.os` is macOS.
- Produces (test support): `String fakeStudio(Directory parent, {String name = 'Android Studio', HostOs? os})`, `String studioJdkHome(String studio, {HostOs? os})`, `void writeInfoPlist(String bundle, {String? version, bool toolbox = false})`; `studioInstalledReason()` also finds `Android Studio*.app` bundles directly in `/Applications` and `~/Applications`.
- The Toolbox note, exactly: `Android Studio at <bundle> is a JetBrains Toolbox launcher. Flutter skips it, and finds Toolbox installs only through Spotlight.`
- The Spotlight command, exactly: `mdfind` with the one argument `kMDItemCFBundleIdentifier="com.google.android.studio*"`. The plist command: `/usr/bin/plutil` with `-convert`, `xml1`, `-o`, `-`, `<plist path>`.

- [ ] **Step 1: Update the test support**

Replace all of `packages/appstein_engine/test/support/fake_android.dart` with:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

/// Creates an Android Studio folder named [name] with a bundled JDK, laid out
/// for [os] (this OS by default), and returns the Android Studio folder. On
/// macOS the folder is the `.app` bundle.
String fakeStudio(
  Directory parent, {
  String name = 'Android Studio',
  HostOs? os,
}) {
  final target = os ?? HostOs.current;
  final studio = p.join(parent.path, name);
  File(
    p.join(
      studioJdkHome(studio, os: target),
      'bin',
      target == HostOs.windows ? 'java.exe' : 'java',
    ),
  ).createSync(recursive: true);
  return studio;
}

/// The JDK folder inside an Android Studio folder, for [os] (this OS by
/// default), for Android Studio 2022 and newer.
String studioJdkHome(String studio, {HostOs? os}) =>
    (os ?? HostOs.current) == HostOs.macos
    ? p.join(studio, 'Contents', 'jbr', 'Contents', 'Home')
    : p.join(studio, 'jbr');

/// Writes a macOS `Contents/Info.plist` into the app [bundle], as XML, with
/// [version] as `CFBundleShortVersionString` when it is set. With [toolbox],
/// it has the `JetBrainsToolboxApp` key a JetBrains Toolbox launcher has.
void writeInfoPlist(String bundle, {String? version, bool toolbox = false}) {
  File(p.join(bundle, 'Contents', 'Info.plist'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<plist version="1.0">',
        '<dict>',
        if (version != null) ...[
          '  <key>CFBundleShortVersionString</key>',
          '  <string>$version</string>',
        ],
        if (toolbox) ...[
          '  <key>JetBrainsToolboxApp</key>',
          '  <string>/Users/me/Applications/Android Studio.app</string>',
        ],
        '</dict>',
        '</plist>',
        '',
      ].join('\n'),
    );
}

/// Writes an Android Studio install record, `<parent>/<folder>/.home`, that
/// names the install folder [studio], as Android Studio does on first start.
void writeStudioRecord(String parent, String folder, String studio) {
  final record = Directory(p.join(parent, folder))..createSync(recursive: true);
  File(p.join(record.path, '.home')).writeAsStringSync(studio);
}

/// A skip reason when this Mac or Linux machine has Android Studio where the
/// Java lookup looks by default, so it would find the real one. Null
/// otherwise. On macOS it checks the `Android Studio*.app` bundles directly
/// in `/Applications` and `~/Applications`.
String? studioInstalledReason() {
  if (Directory('/opt/android-studio').existsSync()) {
    return 'Android Studio is installed at /opt/android-studio on this '
        'machine.';
  }
  if (!Platform.isMacOS) return null;
  final home = Platform.environment['HOME'];
  for (final folder in [
    '/Applications',
    if (home != null) p.join(home, 'Applications'),
  ]) {
    final dir = Directory(folder);
    if (!dir.existsSync()) continue;
    for (final entry in dir.listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is Directory &&
          name.startsWith('Android Studio') &&
          name.endsWith('.app')) {
        return 'Android Studio is installed at ${entry.path} on this machine.';
      }
    }
  }
  return null;
}
```

In `packages/appstein_engine/test/support/temp.dart`, replace the doc comment of `fakeEnvironment`:

```dart
/// A [HostEnvironment] with only [variables], for the real OS unless [os] is
/// given. Pass a fake [os] only to tests that touch no files, or whose files
/// don't depend on the real OS: the macOS Android Studio tests lay out
/// their bundles with `fakeStudio(os: HostOs.macos)` and pass the folders
/// to search, so they run on every OS.
```

- [ ] **Step 2: Write the failing tests**

In `packages/appstein_engine/test/android/java_locator_test.dart`:

(a) Rename the test `'newest version first; a Preview of the same version comes after the release'` to `'newest version first; records are read in name order, so a release comes before its Preview'` (its body stays).

(b) Add inside the group `'choosing among Android Studio installs, as Flutter does'`, after that test:

```dart
    test('equal versions keep the install found first, as in Flutter', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final first = workingStudio(root, 'Studio A');
      final second = workingStudio(root, 'Studio Z');
      // Flutter reads ~/.AndroidStudio* before ~/.cache/Google/AndroidStudio*.
      writeStudioRecord(home, '.AndroidStudio2025.3.4', first);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.3.4',
        second,
      );
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, studioJdkHome(first));
    }, testOn: '!mac-os');
```

(c) Add this group at the end of `main()`:

```dart
  group('macOS, searched as Flutter searches it', () {
    const mac = HostOs.macos;
    const spotlightQuery =
        'kMDItemCFBundleIdentifier="com.google.android.studio*"';
    late Directory root;
    late String apps;
    late String homeApps;

    setUp(() {
      root = tempDir();
      apps = p.join(root.path, 'Applications');
      homeApps = p.join(root.path, 'home', 'Applications');
      Directory(apps).createSync(recursive: true);
      Directory(homeApps).createSync(recursive: true);
    });

    /// An Android Studio app at [bundle] with an Info.plist, whose bundled
    /// JDK runs, or fails when [works] is false.
    String macStudio(
      String bundle, {
      String? version,
      bool works = true,
      bool toolbox = false,
    }) {
      fakeStudio(
        Directory(p.dirname(bundle)),
        name: p.basename(bundle),
        os: mac,
      );
      writeInfoPlist(bundle, version: version, toolbox: toolbox);
      runner.when(
        javaIn(studioJdkHome(bundle, os: mac), mac),
        ['-version'],
        works ? java21 : brokenJava,
      );
      return bundle;
    }

    Future<JavaLookup> lookUp({
      Map<String, Object?> settings = const {},
      Map<String, String> vars = const {},
    }) => locateFlutterJava(
      fakeEnvironment({'HOME': p.join(root.path, 'home'), ...vars}, os: mac),
      settings,
      runner,
      macAppFolders: [apps, homeApps],
    );

    String toolboxNote(String bundle) =>
        'Android Studio at $bundle is a JetBrains Toolbox launcher. Flutter '
        'skips it, and finds Toolbox installs only through Spotlight.';

    test('finds any Android Studio*.app, in a subfolder too', () async {
      final studio = macStudio(
        p.join(apps, 'Dev Tools', 'Android Studio Preview.app'),
        version: '2025.1',
      );
      final lookup = await lookUp();
      expect(lookup.location!.source, JavaSource.androidStudio);
      expect(lookup.location!.home, studioJdkHome(studio, os: mac));
    });

    test('never looks inside another app bundle', () async {
      macStudio(
        p.join(apps, 'Tools.app', 'Android Studio.app'),
        version: '2025.1',
      );
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('does not follow a link to a folder', () async {
      final real = macStudio(
        p.join(root.path, 'elsewhere', 'Android Studio.app'),
        version: '2025.1',
      );
      Link(p.join(apps, 'Android Studio.app')).createSync(real);
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('newest version first, and equal versions keep the one found '
        'first', () async {
      macStudio(p.join(apps, 'Android Studio.app'), version: '2024.3.1');
      // Sorted by name, "Android Studio Preview.app" comes before
      // "Android Studio.app", and /Applications before ~/Applications.
      final first = macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: '2025.1.2',
      );
      macStudio(p.join(homeApps, 'Android Studio.app'), version: '2025.1.2');
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(first, os: mac));
    });

    test('reads the EAP version of a Preview build', () async {
      macStudio(p.join(apps, 'Android Studio.app'), version: '2024.2.1');
      final eap = macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: 'EAP AI-242.21829.142.2422.12358220',
      );
      final lookup = await lookUp();
      // 2422 reads as 2024.2.2, newer than 2024.2.1.
      expect(lookup.location!.home, studioJdkHome(eap, os: mac));
    });

    test("an EAP version it can't read is unknown, so a known version "
        'wins', () async {
      final release = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2024.2.1',
      );
      macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: 'EAP AI-242.21829.142.242.12358220',
      );
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(release, os: mac));
    });

    // Review Focus 2: a Toolbox-only Mac with Spotlight off (mdfind is not
    // faked, so it "can't start").
    test('skips a JetBrains Toolbox launcher, and says why', () async {
      final launcher = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [toolboxNote(launcher)]);
      expect(runner.calls.where((call) => call.endsWith(' -version')), isEmpty);
    });

    test('finds a Toolbox install, or a renamed app, through '
        'Spotlight', () async {
      macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final real = macStudio(
        p.join(root.path, 'Toolbox', 'apps', 'AS.app'),
        version: '2025.1.3',
      );
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 0, stdout: '$real\n'));
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(real, os: mac));
    });

    test('ignores a Spotlight query that fails', () async {
      final other = macStudio(
        p.join(root.path, 'Else', 'AS.app'),
        version: '2025.1',
      );
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 1, stdout: '$other\n'));
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('adds each Spotlight result once, and skips ones that no longer '
        'exist', () async {
      final broken = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        works: false,
      );
      final gone = p.join(root.path, 'gone', 'Android Studio.app');
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 0, stdout: '$broken\n$gone\n'));
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [skippedNote(broken)]);
    });

    test('reads Info.plist through plutil when plutil runs', () async {
      final bundle = p.join(apps, 'Android Studio.app');
      // A binary plist, which only plutil can read.
      final plist = File(p.join(bundle, 'Contents', 'Info.plist'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xd1, 0x01]);
      runner.when(
        '/usr/bin/plutil',
        ['-convert', 'xml1', '-o', '-', plist.path],
        const RunResult(
          exitCode: 0,
          stdout:
              '<plist version="1.0"><dict><key>CFBundleShortVersionString'
              '</key><string>2021.1.1</string></dict></plist>',
        ),
      );
      // Android Studio 2020 and 2021 keep their JDK in jre on macOS.
      final jre = p.join(bundle, 'Contents', 'jre', 'Contents', 'Home');
      File(javaIn(jre, mac)).createSync(recursive: true);
      runner.when(javaIn(jre, mac), ['-version'], java21);
      final lookup = await lookUp();
      expect(lookup.location!.home, jre);
    });

    test('android-studio-dir may name the bundle or its Contents folder, '
        'and then only it counts', () async {
      final configured = macStudio(
        p.join(root.path, 'Custom', 'Android Studio.app'),
        version: '2024.1',
      );
      macStudio(p.join(apps, 'Android Studio.app'), version: '2025.1');
      final lookup = await lookUp(
        settings: {'android-studio-dir': p.join(configured, 'Contents')},
      );
      expect(lookup.location!.home, studioJdkHome(configured, os: mac));
      expect(runner.calls, isNot(contains(startsWith('mdfind'))));
    });

    test('a configured Toolbox launcher is dropped, and the search runs as '
        'if nothing were set', () async {
      final launcher = macStudio(
        p.join(root.path, 'Custom', 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final studio = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2024.1',
      );
      final lookup = await lookUp(settings: {'android-studio-dir': launcher});
      expect(lookup.location!.home, studioJdkHome(studio, os: mac));
      expect(lookup.skipped, [toolboxNote(launcher)]);
    });

    test('no JDK: the installs passed over still come back', () async {
      final broken = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        works: false,
      );
      final lookup = await lookUp();
      expect(lookup.location, isNull);
      expect(lookup.skipped, [skippedNote(broken)]);
    });
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/android/java_locator_test.dart`
Expected: FAIL to compile (`locateFlutterJava` has no `macAppFolders` parameter). Once it compiles with Step 4's signature alone, the macOS group and the tie test fail on the chosen JDK home.

- [ ] **Step 4: Rewrite `java_locator.dart`**

Replace all of `packages/appstein_engine/lib/src/android/java_locator.dart` with:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';

/// Where the JDK that Flutter uses was found.
enum JavaSource {
  /// Set with `flutter config --jdk-dir`.
  flutterConfig('`flutter config --jdk-dir`'),

  /// Bundled with Android Studio.
  androidStudio("Android Studio's bundled JDK"),

  /// The JAVA_HOME environment variable.
  javaHome('JAVA_HOME'),

  /// The `java` command on PATH.
  path('`java` on PATH');

  const JavaSource(this.label);

  /// How the source is shown to people.
  final String label;
}

/// The JDK Flutter would use.
final class JavaLocation {
  /// Creates a location.
  const JavaLocation({
    required this.javaBinary,
    required this.source,
    this.home,
    this.versionOutput,
  });

  /// The `java` executable.
  final String javaBinary;

  /// Where it came from.
  final JavaSource source;

  /// The JDK folder, when known.
  final String? home;

  /// What `java -version` printed, when the lookup already ran it, so callers
  /// need not run it again. Null when the lookup did not run it.
  final String? versionOutput;
}

/// The result of looking for the JDK Flutter uses: the JDK, when there is
/// one, and the Android Studio installs passed over on the way.
final class JavaLookup {
  /// Creates a result.
  const JavaLookup({this.location, this.skipped = const []});

  /// The JDK Flutter would use, or null when it finds none.
  final JavaLocation? location;

  /// Why Flutter passed over Android Studio installs, one line each, in the
  /// order they were tried. It is filled whether or not a JDK was found, so
  /// a missing JDK can be explained too.
  final List<String> skipped;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`, whenever it is text, even empty text, as
///    in Flutter (an empty home gives a relative `bin/java` that won't run);
/// 2. the JDK bundled with Android Studio;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// A `jdk-dir` that is JSON null counts as unset. Any other non-text value
/// is skipped here too; `JavaCheck` reports it, because Flutter stops with
/// an error on it.
///
/// Android Studio is chosen as Flutter's `AndroidStudio.latestValid` chooses
/// it:
/// - when the `android-studio-dir` setting is set, only that install counts
///   (on macOS, unless it is a JetBrains Toolbox launcher, which Flutter
///   drops);
/// - otherwise the installs Flutter knows about are tried newest version
///   first, equal versions in the order they were found. On Windows and
///   Linux they are the ones named by Android Studio's install records (the
///   `.home` files it writes), plus `/opt/android-studio` and
///   `~/android-studio` on Linux. On macOS (`_allMacOS`) they are every
///   `Android Studio*.app` in [macAppFolders], at any depth (by default
///   `/Applications` and `~/Applications`), then the bundles Spotlight's
///   `mdfind` finds by Android Studio's bundle ID, without Toolbox
///   launchers.
///
/// An install counts only if its bundled `java -version`, run with [runner],
/// succeeds. The installs passed over are listed in [JavaLookup.skipped].
Future<JavaLookup> locateFlutterJava(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner, {
  List<String>? macAppFolders,
}) async {
  final configured = settings['jdk-dir'];
  if (configured is String) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(configured, environment),
        source: JavaSource.flutterConfig,
        home: configured,
      ),
    );
  }
  final candidates = await _studioCandidates(
    environment,
    settings,
    runner,
    macAppFolders,
  );
  final skipped = [...candidates.notes];
  for (final studio in candidates.studios) {
    if (!Directory(studio.path).existsSync()) {
      skipped.add(
        '`android-studio-dir` points to ${studio.path}, which does not exist.',
      );
      continue;
    }
    final home = _studioJdkHome(studio, environment);
    final java = _javaIn(home, environment);
    if (!File(java).existsSync()) {
      skipped.add(
        'Android Studio at ${studio.path} has no bundled JDK; '
        'Flutter skips it.',
      );
      continue;
    }
    final result = await runner.run(java, ['-version']);
    if (result.ok) {
      return JavaLookup(
        location: JavaLocation(
          javaBinary: java,
          source: JavaSource.androidStudio,
          home: home,
          versionOutput: '${result.stderr}\n${result.stdout}',
        ),
        skipped: skipped,
      );
    }
    skipped.add(
      'Android Studio at ${studio.path} has a JDK that does not run; '
      'Flutter skips it.',
    );
  }
  final javaHome = environment.variable('JAVA_HOME');
  if (javaHome != null) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(javaHome, environment),
        source: JavaSource.javaHome,
        home: javaHome,
      ),
      skipped: skipped,
    );
  }
  final onPath = findExecutable('java', environment);
  return JavaLookup(
    location: onPath == null
        ? null
        : JavaLocation(javaBinary: onPath, source: JavaSource.path),
    skipped: skipped,
  );
}

/// The major Java version in `java -version` output: 21 for "21.0.2", and 8
/// for the old "1.8.0_202" style. Null when there is no version.
int? parseJavaMajor(String versionOutput) {
  final quoted = RegExp(
    r'version "(\d+)(?:\.(\d+))?',
  ).firstMatch(versionOutput);
  if (quoted != null) {
    final first = int.parse(quoted.group(1)!);
    final second = quoted.group(2);
    return first == 1 && second != null ? int.parse(second) : first;
  }
  final plain = RegExp(r'(?:openjdk|java) (\d+)').firstMatch(versionOutput);
  return plain == null ? null : int.parse(plain.group(1)!);
}

String _javaIn(String home, HostEnvironment environment) =>
    p.join(home, 'bin', environment.os == HostOs.windows ? 'java.exe' : 'java');

/// An Android Studio version, as Flutter's `Version` reads it: major, minor
/// and patch, with missing parts as 0.
typedef _Version = (int, int, int);

/// One Android Studio install that Flutter would consider.
final class _Studio {
  const _Studio(this.path, this.version);

  /// The install folder as people know it (on macOS, the `.app` bundle).
  final String path;

  /// The version, or null when Flutter can't tell.
  final _Version? version;
}

/// The installs to try, in order, and notes about installs left out before
/// trying them (Toolbox launchers).
typedef _Candidates = ({List<_Studio> studios, List<String> notes});

/// The Android Studio installs to try, in order.
Future<_Candidates> _studioCandidates(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner,
  List<String>? macAppFolders,
) async {
  final configured = switch (settings['android-studio-dir']) {
    final String dir when dir.isNotEmpty => dir,
    _ => null,
  };
  if (environment.os == HostOs.macos) {
    final home = environment.homeDir;
    return _macStudioCandidates(
      configured,
      runner,
      macAppFolders ??
          ['/Applications', if (home != null) p.join(home, 'Applications')],
    );
  }
  final studios = _recordedStudios(environment);
  if (configured != null) {
    // Flutter keeps the version of a matching install record, which decides
    // between `jre` and `jbr`.
    final match = studios.where((s) => p.equals(s.path, configured));
    return (
      studios: [_Studio(configured, match.firstOrNull?.version)],
      notes: const <String>[],
    );
  }
  if (environment.os == HostOs.linux) {
    final home = environment.homeDir;
    for (final dir in [
      '/opt/android-studio',
      if (home != null) p.join(home, 'android-studio'),
    ]) {
      if (Directory(dir).existsSync() &&
          !studios.any((s) => p.equals(s.path, dir))) {
        studios.add(_Studio(dir, null));
      }
    }
  }
  return (studios: _newestFirst(studios), notes: const <String>[]);
}

/// Spotlight's query for Android Studio bundles, Preview (`-EAP`) included.
const _spotlightQuery =
    'kMDItemCFBundleIdentifier="com.google.android.studio*"';

/// The macOS installs to try, as Flutter's `_allMacOS` finds them: every
/// `Android Studio*.app` in [appFolders], then Spotlight's results. When
/// [configured] is set and isn't a Toolbox launcher, only it counts.
Future<_Candidates> _macStudioCandidates(
  String? configured,
  ProcessRunner runner,
  List<String> appFolders,
) async {
  final notes = <String>[];
  String? configuredBundle;
  if (configured != null) {
    final bundle = p.basename(configured) == 'Contents'
        ? p.dirname(configured)
        : configured;
    if (!Directory(bundle).existsSync()) {
      // locateFlutterJava reports it as a folder that does not exist.
      return (studios: [_Studio(bundle, null)], notes: notes);
    }
    final studio = await _macStudio(bundle, runner, notes);
    if (studio != null) return (studios: [studio], notes: notes);
    // A Toolbox launcher: Flutter drops it and chooses as if nothing were
    // configured.
    configuredBundle = bundle;
  }
  final bundles = <String>[];
  for (final folder in appFolders) {
    _findStudioBundles(folder, bundles);
  }
  final spotlight = await runner.run('mdfind', [_spotlightQuery]);
  if (spotlight.ok) {
    for (final line in LineSplitter.split(spotlight.stdout)) {
      // Flutter adds a result unless the scan found that exact text. A
      // bundle Spotlight still lists after it was deleted is invalid in
      // Flutter, so it is left out here.
      if (line.isEmpty ||
          bundles.contains(line) ||
          !Directory(line).existsSync()) {
        continue;
      }
      bundles.add(line);
    }
  }
  final studios = <_Studio>[];
  for (final bundle in bundles) {
    if (configuredBundle != null && p.equals(bundle, configuredBundle)) {
      continue;
    }
    final studio = await _macStudio(bundle, runner, notes);
    if (studio != null) studios.add(studio);
  }
  return (studios: _newestFirst(studios), notes: notes);
}

/// Adds to [found] every `Android Studio*.app` folder in [folder], at any
/// depth, as Flutter's `checkForStudio` does: it never looks inside an
/// `.app` bundle and doesn't follow links to folders. Names are matched
/// case-sensitively. Entries are read in name order, so "found first" is
/// the same on every file system.
void _findStudioBundles(String folder, List<String> found) {
  final List<FileSystemEntity> entries;
  try {
    final dir = Directory(folder);
    if (!dir.existsSync()) return;
    entries = dir.listSync(followLinks: false)
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  } on FileSystemException {
    return;
  }
  for (final entry in entries) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    if (name.startsWith('Android Studio') && name.endsWith('.app')) {
      found.add(entry.path);
    } else if (!name.endsWith('.app')) {
      _findStudioBundles(entry.path, found);
    }
  }
}

/// The macOS install in the app [bundle], as Flutter's
/// `AndroidStudio.fromMacOSBundle` reads it, or null for a JetBrains Toolbox
/// launcher, which gets a line in [notes]. The version is the plist's
/// `CFBundleShortVersionString`.
Future<_Studio?> _macStudio(
  String bundle,
  ProcessRunner runner,
  List<String> notes,
) async {
  final plist = await _readInfoPlist(
    p.join(bundle, 'Contents', 'Info.plist'),
    runner,
  );
  if (plist != null && plist.contains('<key>JetBrainsToolboxApp</key>')) {
    notes.add(
      'Android Studio at $bundle is a JetBrains Toolbox launcher. Flutter '
      'skips it, and finds Toolbox installs only through Spotlight.',
    );
    return null;
  }
  final match = plist == null
      ? null
      : RegExp(
          r'<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>',
        ).firstMatch(plist);
  return _Studio(
    bundle,
    match == null ? null : _parseStudioVersion(match[1]!.trim()),
  );
}

/// The Info.plist at [path] as XML, from `/usr/bin/plutil`, which reads the
/// binary plists most apps ship. When plutil can't run (on Windows and
/// Linux, in tests), the file is read as text. Null when there is no
/// readable plist: the version is then unknown, as in Flutter.
Future<String?> _readInfoPlist(String path, ProcessRunner runner) async {
  if (!File(path).existsSync()) return null;
  final xml = await runner.run('/usr/bin/plutil', [
    '-convert',
    'xml1',
    '-o',
    '-',
    path,
  ]);
  if (xml.ok) return xml.stdout;
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Orders installs the way `AndroidStudio.latestValid` prefers them: known
/// versions before unknown ones, newest version first. Equal versions keep
/// the order they were found in, because Flutter replaces its choice only
/// with a strictly newer one. Among unknown versions, the folder that sorts
/// last comes first (Flutter's rule for them).
List<_Studio> _newestFirst(List<_Studio> studios) {
  final order = [for (var i = 0; i < studios.length; i++) i];
  order.sort((i, j) {
    final (a, b) = (studios[i].version, studios[j].version);
    if (a != null && b != null) {
      final byVersion = _compareVersions(b, a);
      return byVersion != 0 ? byVersion : i.compareTo(j);
    }
    if (a != null) return -1;
    if (b != null) return 1;
    return studios[j].path.compareTo(studios[i].path);
  });
  return [for (final i in order) studios[i]];
}

int _compareVersions(_Version a, _Version b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
  return a.$3.compareTo(b.$3);
}

/// Reads a version the way Flutter's `Version.parse` does: digits at the
/// start of [text], such as `2025.3.4`. Null when [text] doesn't start with
/// one, as in `Preview2024.2`.
_Version? _parseVersion(String text) {
  final match = RegExp(r'^(\d+)(?:\.(\d+)(?:\.(\d+))?)?').firstMatch(text);
  if (match == null) return null;
  final major = int.tryParse(match[1]!);
  final minor = int.tryParse(match[2] ?? '0');
  final patch = int.tryParse(match[3] ?? '0');
  if (major == null || minor == null || patch == null) return null;
  return (major, minor, patch);
}

/// Reads a macOS Info.plist version as Flutter's
/// `AndroidStudio._parseVersion` does. A Preview's
/// `EAP AI-242.21829.142.2422.12358220` becomes 2024.2.2, from the four
/// digits `2422`; any other count of digits there gives null. Other text is
/// read like [_parseVersion].
_Version? _parseStudioVersion(String text) {
  final eap = RegExp(
    r'EAP\s+[A-Z]{2}-\d+\.\d+\.\d+\.(\d+)\.\d+',
  ).firstMatch(text);
  if (eap == null) return _parseVersion(text);
  final digits = eap[1]!;
  if (digits.length != 4) return null;
  return (
    int.parse('20${digits.substring(0, 2)}'),
    int.parse(digits[2]),
    int.parse(digits[3]),
  );
}

/// The bundled JDK folder Flutter uses in [studio]
/// (`AndroidStudio._initAndValidate` in `android_studio.dart`): `jre` before
/// Android Studio 2022, `jbr` from then on and when the version is unknown.
String _studioJdkHome(_Studio studio, HostEnvironment environment) {
  final major = studio.version?.$1;
  if (environment.os != HostOs.macos) {
    return p.join(studio.path, major != null && major < 2022 ? 'jre' : 'jbr');
  }
  final contents = p.join(studio.path, 'Contents');
  if (major != null && major < 2020) {
    return p.join(contents, 'jre', 'jdk', 'Contents', 'Home');
  }
  if (major != null && major < 2022) {
    return p.join(contents, 'jre', 'Contents', 'Home');
  }
  return p.join(contents, 'jbr', 'Contents', 'Home');
}

/// Android Studio's settings folders: `AndroidStudio2025.3` or
/// `.AndroidStudio3.5`, with the app name and the version as groups
/// (`_dotHomeStudioVersionMatcher` in `android_studio.dart`).
final _settingsFolder = RegExp(r'^\.?(AndroidStudio[^\d]*)([\d.]+)');

/// The Android Studio installs named by the `.home` files that Android
/// Studio writes, on Windows and Linux (`_allLinuxOrWindows` in
/// `android_studio.dart`), in the order Flutter finds them:
/// - `~/.AndroidStudio*`, then `~/.cache/Google/AndroidStudio*`;
/// - `%LOCALAPPDATA%\Google\AndroidStudio*` on Windows.
///
/// When several records name one install, it keeps the newest version, as
/// Flutter does. Never throws: unreadable files and missing folders are
/// skipped.
List<_Studio> _recordedStudios(HostEnvironment environment) {
  final studios = <_Studio>[];
  void add(_Studio studio) {
    final version = studio.version;
    final alreadyFound = studios.any(
      (other) =>
          p.equals(other.path, studio.path) &&
          (version == null ||
              (other.version != null &&
                  _compareVersions(other.version!, version) >= 0)),
    );
    if (alreadyFound) return;
    studios
      ..removeWhere((other) => p.equals(other.path, studio.path))
      ..add(studio);
  }

  final home = environment.homeDir;
  if (home != null) {
    for (final parent in [home, p.join(home, '.cache', 'Google')]) {
      for (final folder in _foldersIn(parent)) {
        final match = _settingsFolder.firstMatch(p.basename(folder));
        final version = match == null ? null : _parseVersion(match[2]!);
        if (match == null || version == null) continue;
        // Android Studio 4.1 moved the record out of `system`.
        final record = version.$1 >= 4 && version.$2 >= 1
            ? p.join(folder, '.home')
            : p.join(folder, 'system', '.home');
        final install = _readInstallRecord(record);
        if (install != null) add(_Studio(install, version));
      }
    }
  }
  final localAppData = environment.variable('LOCALAPPDATA');
  if (environment.os == HostOs.windows && localAppData != null) {
    for (final folder in _foldersIn(p.join(localAppData, 'Google'))) {
      final name = p.basename(folder);
      for (final id in const ['AndroidStudio', 'AndroidStudioPreview']) {
        if (!name.startsWith(id)) continue;
        final install = _readInstallRecord(p.join(folder, '.home'));
        if (install != null) {
          add(_Studio(install, _parseVersion(name.substring(id.length))));
        }
      }
    }
  }
  return studios;
}

/// The install folder a `.home` record names, or null when the record or
/// the folder is missing or unreadable.
String? _readInstallRecord(String file) {
  try {
    final install = File(file).readAsStringSync().trim();
    return install.isNotEmpty && Directory(install).existsSync()
        ? install
        : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The folders directly inside [parent], in name order (Flutter uses the
/// file system's order, which is alphabetical on NTFS and APFS); empty when
/// it can't be listed.
List<String> _foldersIn(String parent) {
  try {
    final dir = Directory(parent);
    if (!dir.existsSync()) return const [];
    return [
      for (final entry in dir.listSync(followLinks: false))
        if (entry is Directory) entry.path,
    ]..sort((a, b) => p.basename(a).compareTo(p.basename(b)));
  } on FileSystemException {
    return const [];
  }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test test/android/java_locator_test.dart test/doctor/checks/java_check_test.dart`
Expected: all pass, on Windows too (the macOS group runs everywhere). If `does not follow a link to a folder` fails only on Windows because `listSync(followLinks: false)` reports the junction as a folder, stop and report it rather than weakening the test.

- [ ] **Step 6: Update the guide**

(a) In `docs/guide/sdk-lookups.md`, `### Which Android Studio`:
- Replace the bullet `- **When \`android-studio-dir\` is set, only that install counts.** …` with:

```markdown
- **When `android-studio-dir` is set, only that install counts.** On Windows and Linux its version comes from a matching install record. On macOS it comes from the app's `Info.plist`, and the setting may name the `.app` bundle or its `Contents` folder. One exception, as in Flutter: on macOS, a JetBrains Toolbox launcher named there is dropped, and the search below runs as if nothing were set.
```

- Replace the bullet `  - **macOS:** only \`Android Studio.app\` in \`/Applications\` and \`~/Applications\`, with the version from its \`Info.plist\`.` with:

```markdown
  - **macOS,** as Flutter's `_allMacOS`, in this order:
    1. every `Android Studio*.app` bundle in `/Applications`, then in `~/Applications`, at any depth. The search never looks inside an `.app` bundle and doesn't follow links to folders. Names are matched case-sensitively, so `Android Studio Preview.app` counts and a renamed `AS.app` doesn't;
    2. every bundle Spotlight knows by Android Studio's bundle ID (`mdfind 'kMDItemCFBundleIdentifier="com.google.android.studio*"'`), unless the scan already found that exact path. If `mdfind` can't run or fails, this step adds nothing.

    Each bundle's `Contents/Info.plist` is read with `/usr/bin/plutil -convert xml1 -o - <plist>`, which also reads the binary plists most apps ship, or as plain text when `plutil` can't run. A bundle whose plist has the `JetBrainsToolboxApp` key is a JetBrains Toolbox launcher, not an install. Flutter skips it, and so does Appstein, with a `skipped` line saying so. The real Toolbox install is found only through Spotlight, so with Spotlight indexing off, a Toolbox-only Mac has no Android Studio JDK, in Flutter and in doctor alike. The version is the plist's `CFBundleShortVersionString`. A Preview's `EAP AI-242.21829.142.2422.12358220` becomes 2024.2.2, from the four digits `2422`, as in Flutter.

    `locateFlutterJava` takes the folders to search as `macAppFolders`, so the tests run this search in temporary folders on every OS.
```

- Replace the bullet `- **Newest first:** …` with:

```markdown
- **Newest first:** known versions before unknown ones, newest version first. Equal versions keep the install found first, because Flutter only replaces its choice with a strictly newer one. Folders are read in name order so that "found first" is the same on every machine; Flutter uses the file system's own order, which is alphabetical on NTFS and APFS. So on Windows and Linux a release's record (`AndroidStudio2025.3`) comes before a Preview's of the same version (`AndroidStudioPreview2025.3`). Among installs of unknown version, the folder whose path sorts last comes first, Flutter's rule for them.
```

- Replace the bullet `- **JetBrains Toolbox installs are not searched.**` with:

```markdown
- **On Windows and Linux, JetBrains Toolbox installs are found only through the `.home` records Android Studio writes,** as in Flutter.
```

- In `## Known gaps`, delete the bullet that starts `- **macOS Android Studio discovery is narrower than Flutter's.**`, and add at the end of the list:

```markdown
- **A configured Android Studio on Windows.** Flutter reads `android-studio-dir` only after it has listed `%LOCALAPPDATA%\Google`, and skips the setting when that folder is missing. That is a Flutter bug in a rare case, and Appstein doesn't copy it: it always uses the configured install, because the setting is the user's explicit choice.
```

(b) In `docs/guide/testing.md`, replace the table row for `fakeStudio`, `writeStudioRecord` with:

```markdown
| `fakeStudio`, `writeStudioRecord`, `writeInfoPlist` | [`fake_android.dart`](../../packages/appstein_engine/test/support/fake_android.dart) | An Android Studio folder with a bundled JDK, laid out for this OS or for the `os` you pass (a macOS `.app` bundle on any OS), the `.home` install record Android Studio writes, and a macOS `Info.plist` with a version or the JetBrains Toolbox key. `studioInstalledReason` skips a test when a real Android Studio in a default place would get in the way |
```

and in the `fakeEnvironment` row, replace `for the real OS unless you pass one.` with `for the real OS unless you pass one. A fake OS is for tests that touch no files, or whose files don't depend on the real OS, such as the macOS Android Studio tests, which pass their own folders to search.`

(c) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.`

- [ ] **Step 7: Format, analyze and run the engine tests**

Run: `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, then (in `packages/appstein_engine`) `fvm dart test`
Expected: clean; all pass.

- [ ] **Step 8: Hand back to the controller to commit**

Suggested message: `feat(java): find macOS Android Studio as Flutter does: recursive scan, Spotlight, plutil, Toolbox and EAP rules`

---

### Task 5: The OS's reason in file errors (R11)

**Files:**
- Create: `packages/appstein_engine/lib/src/host/file_errors.dart`
- Create: `packages/appstein_engine/test/host/file_errors_test.dart`
- Modify: `packages/appstein_engine/lib/src/config/config_loader.dart:64-72`, `packages/appstein_engine/lib/src/doctor/checks/project_check.dart:30-55`, `packages/appstein_engine/lib/src/sdk/fvm_pin.dart:74-77`, `packages/appstein_engine/lib/src/sdk/flutter_sdk_reader.dart:52-55`
- Modify: `packages/appstein_engine/test/doctor/checks/project_check_test.dart`
- Modify: `docs/guide/running-tools.md`, `docs/guide/config.md`, `docs/guide/doctor.md`, `docs/guide/sdk-lookups.md`, `docs/guide/architecture.md`

**Interfaces:**
- Produces (engine-internal, not exported): `String fileErrorReason(FileSystemException error)`: the OS error's message when it is non-empty, else `error.message`. Task 6's FVM settings reader uses it.
- ProjectCheck's fix hint for a `ConfigException` whose `line` is null, exactly: `Make sure appstein.yaml is a readable UTF-8 text file.`

- [ ] **Step 1: Write the failing tests**

`packages/appstein_engine/test/host/file_errors_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/src/host/file_errors.dart';
import 'package:test/test.dart';

void main() {
  test("uses the operating system's reason when it gave one", () {
    expect(
      fileErrorReason(
        const FileSystemException(
          'Cannot open file',
          'appstein.yaml',
          OSError('Access is denied.', 5),
        ),
      ),
      'Access is denied.',
    );
  });

  test("falls back to Dart's message", () {
    expect(
      fileErrorReason(
        const FileSystemException(
          "Failed to decode data using encoding 'utf-8'",
          'appstein.yaml',
        ),
      ),
      "Failed to decode data using encoding 'utf-8'",
    );
    expect(
      fileErrorReason(
        const FileSystemException('Cannot open file', 'x', OSError()),
      ),
      'Cannot open file',
    );
  });
}
```

Add to `packages/appstein_engine/test/doctor/checks/project_check_test.dart`, at the end of `main()`:

```dart
  test('an appstein.yaml that cannot be read gets a fix without a '
      'position', () async {
    File(
      p.join(project.path, 'appstein.yaml'),
    ).writeAsBytesSync([0x61, 0x3a, 0x20, 0xff, 0xfe, 0x0a]);
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('Could not read appstein.yaml'));
    expect(
      result.fixHint,
      'Make sure appstein.yaml is a readable UTF-8 text file.',
    );
  });
```

- [ ] **Step 2: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/host/file_errors_test.dart test/doctor/checks/project_check_test.dart`
Expected: `file_errors_test.dart` fails to compile (no such file); the new project test fails on the fix hint (it gets "Fix appstein.yaml at the position shown…").

- [ ] **Step 3: Write the helper and use it**

`packages/appstein_engine/lib/src/host/file_errors.dart`:

```dart
import 'dart:io';

/// Why a file operation failed, for a message: the operating system's own
/// words when it gave any (such as "Access is denied." or "Permission
/// denied"), or else Dart's message (such as a file that isn't valid
/// UTF-8, where there is no OS error).
String fileErrorReason(FileSystemException error) {
  final os = error.osError?.message;
  return os == null || os.isEmpty ? error.message : os;
}
```

In `packages/appstein_engine/lib/src/config/config_loader.dart`, add `import '../host/file_errors.dart';` just before `import '../text/edit_distance.dart';` (imports stay sorted). Then replace the `on FileSystemException` block of `loadConfig` with:

```dart
  } on FileSystemException catch (error) {
    // For example a file that isn't UTF-8, or one that is locked.
    throw ConfigException(
      'Could not read $configFileName: ${fileErrorReason(error)}',
      sourcePath: file.path,
    );
  }
```

In `packages/appstein_engine/lib/src/doctor/checks/project_check.dart`, add `import '../../host/file_errors.dart';` after `import '../../config/config_loader.dart';`, then:
- replace `'Could not read pubspec.yaml: ${error.message}',` with `'Could not read pubspec.yaml: ${fileErrorReason(error)}',`;
- replace the `on ConfigException` block with:

```dart
    } on ConfigException catch (error) {
      return CheckResult.error(
        'appstein.yaml is invalid: $error',
        details: [root],
        // Without a line, the file couldn't be read at all.
        fixHint: error.line == null
            ? 'Make sure appstein.yaml is a readable UTF-8 text file.'
            : 'Fix appstein.yaml at the position shown. Every key and '
                  'its default are listed in section 7 of the Appstein spec.',
      );
    }
```

In `packages/appstein_engine/lib/src/sdk/fvm_pin.dart`, add `import '../host/file_errors.dart';` after the `path` import, and replace `'Could not read ${file.path}: ${error.osError?.message ?? error.message}',` with `'Could not read ${file.path}: ${fileErrorReason(error)}',`.

In `packages/appstein_engine/lib/src/sdk/flutter_sdk_reader.dart`, add `import '../host/file_errors.dart';` after the `path` import, and make the same replacement.

- [ ] **Step 4: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test`
Expected: all pass, including `config_loader_test.dart`'s `a file that is not valid UTF-8 is a ConfigException naming it`.

- [ ] **Step 5: Update the guide**

(a) `docs/guide/running-tools.md`: add at the end of the page:

```markdown
## `fileErrorReason`

[`file_errors.dart`](../../packages/appstein_engine/lib/src/host/file_errors.dart) turns a `FileSystemException` into the reason a message should show: the operating system's own words when it gave any, such as "Access is denied." for a locked file on Windows or "Permission denied" elsewhere, or else Dart's message, such as the one for a file that isn't valid UTF-8, where there is no OS error. Every file error the engine reports goes through it: `appstein.yaml`, `pubspec.yaml`, the FVM pin and settings, and Flutter's version file. It is used only inside the engine, so the barrel doesn't export it.
```

(b) `docs/guide/config.md`: replace `A file that exists but can't be read (not UTF-8, or locked) is a \`ConfigException\`.` with `A file that exists but can't be read (not UTF-8, or locked) is a \`ConfigException\` without a line, whose message gives the reason, in the OS's words when it gave any ("Access is denied."; see [running-tools](running-tools.md#fileerrorreason)).`

(c) `docs/guide/doctor.md`, in the `ProjectCheck` table, replace the rows for `pubspec.yaml` and an invalid `appstein.yaml` with:

```markdown
| `pubspec.yaml` can't be read | `error`, with the file and the reason |
| `appstein.yaml` can't be read | `error`, with the reason; the fix says to make it a readable UTF-8 file |
| `appstein.yaml` is invalid | `error`, saying where: the file, and the line and column |
```

(d) `docs/guide/sdk-lookups.md`, in `### FVM pins`, replace `the lookup stops with "Could not read the FVM pin".` with `the lookup stops with "Could not read the FVM pin", and the message gives the reason, in the OS's words when it gave any.`

(e) `docs/guide/architecture.md`, `## What the engine exports`: append to the paragraph: ` A few helpers that only the engine itself uses, such as \`readAndroidSdkContents\` and \`fileErrorReason\`, live under \`lib/src/\` without an export; their tests import them from \`src/\` directly.`

(f) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.`

- [ ] **Step 6: Format and analyze**

Run: `fvm dart format --output=none --set-exit-if-changed .`, then `fvm dart analyze --fatal-infos`
Expected: clean.

- [ ] **Step 7: Hand back to the controller to commit**

Suggested message: `fix(engine): give the OS's reason in file errors, and a fitting fix for an unreadable appstein.yaml`

---

### Task 6: FVM pins and cache, FLUTTER_ROOT notes, and "No Flutter SDK" wording (R7, R8, R9', R10; R6 in the guide)

**Files:**
- Modify: `packages/appstein_engine/lib/src/sdk/fvm_pin.dart` (whole file)
- Modify: `packages/appstein_engine/lib/src/sdk/flutter_sdk_locator.dart` (whole file)
- Modify: `packages/appstein_engine/lib/src/sdk/sdk_detector.dart` (the unmet-pin block, a new method, one import)
- Modify: `packages/appstein_engine/lib/src/doctor/checks/fvm_check.dart` (whole file), `packages/appstein_engine/lib/src/doctor/checks/flutter_check.dart` (the details list, one import)
- Modify: `packages/appstein_engine/test/support/doctor_support.dart` (`foundSdk`), `packages/appstein_engine/test/support/fake_sdk.dart` (two helpers)
- Modify: `packages/appstein_engine/test/sdk/fvm_pin_test.dart`, `packages/appstein_engine/test/sdk/flutter_sdk_locator_test.dart`, `packages/appstein_engine/test/sdk/sdk_detector_test.dart`, `packages/appstein_engine/test/doctor/checks/fvm_check_test.dart`, `packages/appstein_engine/test/doctor/checks/flutter_check_test.dart`
- Modify: `docs/guide/sdk-lookups.md`, `docs/guide/doctor.md`, `docs/guide/testing.md`

**Interfaces:**
- Consumes: Task 5's `fileErrorReason`.
- Produces (exported through the existing barrel exports of `fvm_pin.dart` and `flutter_sdk_locator.dart`):
  - `const fvmChannels = ['stable', 'beta', 'dev', 'master', 'main']`;
  - `String? fvmPinChannel(String pin)`, `String? fvmPinVersion(String pin)`, `String describeFvmPin(String pin)`, `String fvmInstallHint(String pin)`;
  - `FvmPin` gains `final String? cachePath` (absolute; a relative value resolved against `pinDirectory`) and getters `String? channel`, `String? flutterVersion`;
  - `String? fvmGlobalConfigPath(HostEnvironment environment)`; `final class FvmGlobalConfig { String path; String? cachePath; String? problem; }`; `FvmGlobalConfig? readFvmGlobalConfig(HostEnvironment environment)`; `String? fvmCacheFolder(FvmPin pin, HostEnvironment environment)`;
  - `SdkLocation` gains `final List<String> notes` (default `const []`).
- Produces (test support): `foundSdk(..., List<String> notes = const [])`; `Map<String, String> fvmHomeVars(String home)` and `String fvmSettingsFile(String home)` in `fake_sdk.dart`.
- The messages, exactly:
  - `describeFvmPin`: `Flutter 3.47.5` / `the Flutter stable channel` / `Flutter 3.24.0 on the beta channel`;
  - `fvmInstallHint`: ``Run `fvm install stable` or `fvm use stable` in the project folder.`` for a channel, ``Run `fvm install <pin>` in the project folder.`` otherwise;
  - the FLUTTER_ROOT note: `FLUTTER_ROOT is set to <path>, which is not a Flutter SDK, so it was ignored.`;
  - the failure: ``No Flutter SDK found. Tried: <parts>.`` with parts, comma-separated, in order: `the project's FVM pin (<describeFvmPin>, from <pin file>, not installed)` or `no FVM pin in the project` (only with a project root); `FLUTTER_ROOT (not set)` or `FLUTTER_ROOT (set to <path>, not an SDK)`; `` `flutter` on PATH (not found)`` or `` `flutter` on PATH (found at <path>, not inside an SDK)``;
  - the detector's unmet-pin failure: `The project pins <describeFvmPin> with FVM, but FVM does not have it installed, and the Flutter found through <source> is <version>.`, where `<version>` is `on the <channel> channel` for a bare channel pin;
  - FvmCheck: ok `Project pins <describeFvmPin> (<pin file name>)`; warning `The project pins <describeFvmPin> with FVM, but \`fvm\` is not on PATH.`; the settings line `FVM's settings file can't be used, and FVM stops with an error until it is fixed: <problem>`;
  - FlutterCheck, for an unmet bare channel pin: `The project pins the Flutter <channel> channel with FVM; FVM does not have it, so this Flutter on that channel is used.`

- [ ] **Step 1: Update the test support**

In `packages/appstein_engine/test/support/doctor_support.dart`, replace `foundSdk` with:

```dart
/// A successful SDK detection with the given versions, and the lookup's
/// [notes].
SdkDetection foundSdk({
  String flutter = '3.47.5',
  String channel = 'stable',
  String root = '/sdk',
  SdkSource source = SdkSource.path,
  String? unmetFvmPin,
  List<String> notes = const [],
}) => SdkDetection.found(
  SdkInfo(flutterVersion: flutter, dartVersion: '3.13.4', channel: channel),
  SdkLocation(
    root: root,
    source: source,
    unmetFvmPin: unmetFvmPin,
    notes: notes,
  ),
);
```

In `packages/appstein_engine/test/support/fake_sdk.dart`, add `import 'package:appstein_engine/appstein_engine.dart';` before the `path` import, and add at the end:

```dart
/// Variables that make [home] the user's home folder, and the folder FVM's
/// global settings file lives under, for this OS (see [fvmSettingsFile]).
Map<String, String> fvmHomeVars(String home) => switch (HostOs.current) {
  HostOs.windows => {'USERPROFILE': home, 'APPDATA': home},
  HostOs.macos => {'HOME': home},
  HostOs.linux => {'HOME': home, 'XDG_CONFIG_HOME': home},
};

/// Where FVM's global settings file is, with the variables of
/// [fvmHomeVars] for [home].
String fvmSettingsFile(String home) => switch (HostOs.current) {
  HostOs.windows || HostOs.linux => p.join(home, 'fvm', '.fvmrc'),
  HostOs.macos => p.join(
    home,
    'Library',
    'Application Support',
    'fvm',
    '.fvmrc',
  ),
};
```

- [ ] **Step 2: Write the failing tests**

(a) `packages/appstein_engine/test/sdk/fvm_pin_test.dart`: add `import 'dart:convert';` and `import '../support/fake_sdk.dart';`, then add at the end of `main()`:

```dart
  group('what a pin names', () {
    test('a channel', () {
      for (final channel in ['stable', 'beta', 'dev', 'master', 'main']) {
        expect(fvmPinChannel(channel), channel);
        expect(fvmPinVersion(channel), isNull);
        expect(describeFvmPin(channel), 'the Flutter $channel channel');
        expect(
          fvmInstallHint(channel),
          'Run `fvm install $channel` or `fvm use $channel` in the project '
          'folder.',
        );
      }
    });

    test('a version on a channel', () {
      expect(fvmPinChannel('3.24.0@beta'), 'beta');
      expect(fvmPinVersion('3.24.0@beta'), '3.24.0');
      expect(describeFvmPin('3.24.0@beta'), 'Flutter 3.24.0 on the beta channel');
      expect(
        fvmInstallHint('3.24.0@beta'),
        'Run `fvm install 3.24.0@beta` in the project folder.',
      );
    });

    test('a version, a git ref, or a text FVM would reject', () {
      for (final pin in ['3.47.5', 'f4c9b2a1e0', '3.24.0@nightly']) {
        expect(fvmPinChannel(pin), isNull);
        expect(fvmPinVersion(pin), pin);
        expect(describeFvmPin(pin), 'Flutter $pin');
        expect(
          fvmInstallHint(pin),
          'Run `fvm install $pin` in the project folder.',
        );
      }
    });
  });

  test('reads cachePath from the pin file, relative to its folder', () {
    final dir = tempDir();
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5", "cachePath": "my cache"}');
    expect(readFvmPin(dir.path)!.cachePath, p.join(dir.path, 'my cache'));
  });

  test('keeps an absolute cachePath, and ignores an empty one', () {
    final dir = tempDir();
    final absolute = p.join(tempDir().path, 'cache');
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync(jsonEncode({'flutter': '3.47.5', 'cachePath': absolute}));
    expect(readFvmPin(dir.path)!.cachePath, absolute);
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5", "cachePath": ""}');
    expect(readFvmPin(dir.path)!.cachePath, isNull);
  });

  group("FVM's global settings", () {
    test('live where FVM keeps them on each OS', () {
      expect(
        fvmGlobalConfigPath(
          fakeEnvironment({'APPDATA': 'roaming'}, os: HostOs.windows),
        ),
        p.join('roaming', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({'HOME': 'me'}, os: HostOs.macos)),
        p.join('me', 'Library', 'Application Support', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({'HOME': 'me'}, os: HostOs.linux)),
        p.join('me', '.config', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(
          fakeEnvironment({
            'HOME': 'me',
            'XDG_CONFIG_HOME': 'xdg',
          }, os: HostOs.linux),
        ),
        p.join('xdg', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({}, os: HostOs.windows)),
        isNull,
      );
    });

    test('are read for cachePath; a missing file is null', () {
      final home = tempDir().path;
      final environment = fakeEnvironment(fvmHomeVars(home));
      expect(readFvmGlobalConfig(environment), isNull);
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"cachePath": "D:/fvm cache"}');
      final config = readFvmGlobalConfig(environment)!;
      expect(config.path, fvmSettingsFile(home));
      expect(config.cachePath, 'D:/fvm cache');
      expect(config.problem, isNull);
    });

    test('that are not JSON give a problem, not an exception', () {
      final home = tempDir().path;
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      final config = readFvmGlobalConfig(fakeEnvironment(fvmHomeVars(home)))!;
      expect(config.cachePath, isNull);
      expect(
        config.problem,
        startsWith('${fvmSettingsFile(home)} is not valid JSON: '),
      );
    });
  });

  test("fvmCacheFolder: the pin file, FVM_CACHE_PATH, FVM_HOME, FVM's "
      'global settings, then ~/fvm', () {
    final home = tempDir().path;
    final globalCache = p.join(home, 'global cache');
    File(fvmSettingsFile(home))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'cachePath': globalCache}));
    FvmPin pinWith([String? cachePath]) => FvmPin(
      version: '3.47.5',
      configPath: p.join(home, '.fvmrc'),
      pinDirectory: home,
      cachePath: cachePath,
    );
    String? folder(FvmPin pin, Map<String, String> vars) => fvmCacheFolder(
      pin,
      fakeEnvironment({...fvmHomeVars(home), ...vars}),
    );
    const both = {'FVM_CACHE_PATH': 'env cache', 'FVM_HOME': 'fvm home'};
    expect(folder(pinWith('pin cache'), both), 'pin cache');
    expect(folder(pinWith(), both), 'env cache');
    expect(folder(pinWith(), {'FVM_HOME': 'fvm home'}), 'fvm home');
    expect(folder(pinWith(), {}), globalCache);
    File(fvmSettingsFile(home)).deleteSync();
    expect(folder(pinWith(), {}), p.join(home, 'fvm'));
  });
```

(b) `packages/appstein_engine/test/sdk/flutter_sdk_locator_test.dart`:
- add `import 'dart:convert';` at the top;
- delete the tests `'a flutter on PATH that is not inside an SDK says so'` and `'with nothing installed, explains what to do'` (the new group below replaces them);
- in the group `'a stale .fvm/flutter_sdk link'`, add after the test `'is still used when the pin is a channel name'`:

```dart
    // Review Focus 4.
    test('a version@channel pin compares its version and has its own cache '
        'folder', () {
      pin('3.24.0@beta');
      final sdk = createFakeSdk(
        p.join(cache, 'versions', '3.24.0@beta'),
        flutter: '3.24.0',
        channel: 'beta',
      );
      final location = locate().location!;
      expect(p.equals(location.root, sdk), isTrue);
      expect(location.fvmVersion, '3.24.0@beta');
    });
```

- add at the end of `main()`:

```dart
  group("FVM's cache folder", () {
    test("the pin file's cachePath comes first, relative to the pin's "
        'folder', () {
      File(p.join(project, '.fvmrc')).writeAsStringSync(
        jsonEncode({'flutter': '3.47.5', 'cachePath': 'my cache'}),
      );
      final sdk = createFakeSdk(
        p.join(project, 'my cache', 'versions', '3.47.5'),
      );
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(p.equals(lookup.location!.root, sdk), isTrue);
    });

    test('FVM_HOME is used when FVM_CACHE_PATH is not set', () {
      pin('3.47.5');
      final fvmHome = p.join(work.path, 'fvm home');
      createFakeSdk(p.join(fvmHome, 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_HOME': fvmHome}),
      ).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
    });

    test("FVM's global settings give the cache when nothing else does", () {
      pin('3.47.5');
      final home = p.join(work.path, 'home');
      final cache = p.join(work.path, 'global cache');
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'cachePath': cache}));
      final sdk = createFakeSdk(p.join(cache, 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment(fvmHomeVars(home)),
      ).locate(projectRoot: project);
      expect(p.equals(lookup.location!.root, sdk), isTrue);
    });

    // Review Focus 3.
    test('a global settings file that is not JSON is ignored', () {
      pin('3.47.5');
      final home = p.join(work.path, 'home');
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      createFakeSdk(p.join(home, 'fvm', 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment(fvmHomeVars(home)),
      ).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
    });
  });

  test('a FLUTTER_ROOT that is not an SDK is skipped, with a note', () {
    final bad = p.join(work.path, 'not an sdk');
    final sdk = createFakeSdk(p.join(work.path, 'päth sdk'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({
        'FLUTTER_ROOT': bad,
        'PATH': p.join(sdk, 'bin'),
        'PATHEXT': defaultPathExt,
      }),
    ).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.path);
    expect(lookup.location!.notes, [
      'FLUTTER_ROOT is set to $bad, which is not a Flutter SDK, so it was '
          'ignored.',
    ]);
  });

  group('when no SDK is found, the problem names what was tried', () {
    const installHint =
        'Install Flutter (https://docs.flutter.dev/get-started/install), or '
        'pin a version in the project with `fvm use <version>`.';

    test('in a project without a pin', () {
      final lookup = FlutterSdkLocator(
        fakeEnvironment({}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        'No Flutter SDK found. Tried: no FVM pin in the project, '
        'FLUTTER_ROOT (not set), `flutter` on PATH (not found).',
      );
      expect(lookup.fixHint, installHint);
    });

    test('outside a project, without the FVM part', () {
      expect(
        FlutterSdkLocator(fakeEnvironment({})).locate().problem,
        'No Flutter SDK found. Tried: FLUTTER_ROOT (not set), `flutter` on '
        'PATH (not found).',
      );
    });

    test('with a pin FVM does not have', () {
      pin('3.46.0');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        "No Flutter SDK found. Tried: the project's FVM pin (Flutter 3.46.0, "
        'from ${p.join(project, '.fvmrc')}, not installed), FLUTTER_ROOT '
        '(not set), `flutter` on PATH (not found).',
      );
      expect(lookup.fixHint, 'Run `fvm install 3.46.0` in the project folder.');
    });

    test('with a channel pin FVM does not have', () {
      pin('stable');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        contains("the project's FVM pin (the Flutter stable channel, from "),
      );
      expect(
        lookup.fixHint,
        'Run `fvm install stable` or `fvm use stable` in the project folder.',
      );
    });

    test('with a FLUTTER_ROOT that is not an SDK, and a flutter on PATH '
        'outside one', () {
      final bad = p.join(work.path, 'not an sdk');
      final tools = Directory(p.join(work.path, 'shims'))..createSync();
      final shim = fakeExecutable(tools, 'flutter');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({
          'FLUTTER_ROOT': bad,
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        'No Flutter SDK found. Tried: no FVM pin in the project, '
        'FLUTTER_ROOT (set to $bad, not an SDK), `flutter` on PATH (found at '
        '$shim, not inside an SDK).',
      );
    });
  });
```

(c) `packages/appstein_engine/test/sdk/sdk_detector_test.dart`, add at the end of `main()`:

```dart
  group('when an FVM channel pin is not installed', () {
    late Directory work;
    late String project;

    setUp(() {
      work = tempDir();
      project = p.join(work.path, 'my app');
      Directory(project).createSync();
      File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: a\n');
    });

    SdkDetection detect(String pin, String sdk) {
      File(
        p.join(project, '.fvmrc'),
      ).writeAsStringSync('{"flutter": "$pin"}');
      return SdkDetector(
        fakeEnvironment({
          'FVM_CACHE_PATH': p.join(work.path, 'empty'),
          'FLUTTER_ROOT': sdk,
        }),
      ).detect(projectRoot: project);
    }

    test('an SDK on that channel meets it', () {
      final detection = detect(
        'stable',
        createFakeSdk(p.join(work.path, 'sdk')),
      );
      expect(detection.info!.fvmVersion, 'stable');
    });

    test('main and master are one channel', () {
      final detection = detect(
        'main',
        createFakeSdk(
          p.join(work.path, 'sdk'),
          flutter: '3.48.0-1.0.pre',
          channel: 'master',
        ),
      );
      expect(detection.info, isNotNull);
    });

    test('an SDK on another channel fails, naming both channels', () {
      final detection = detect(
        'stable',
        createFakeSdk(p.join(work.path, 'sdk'), channel: 'beta'),
      );
      expect(
        detection.problem,
        'The project pins the Flutter stable channel with FVM, but FVM does '
        'not have it installed, and the Flutter found through FLUTTER_ROOT '
        'is on the beta channel.',
      );
      expect(
        detection.fixHint,
        'Run `fvm install stable` or `fvm use stable` in the project folder.',
      );
    });

    // Review Focus 4.
    test('a version@channel pin compares the version', () {
      final met = detect(
        '3.24.0@beta',
        createFakeSdk(p.join(work.path, 'a'), flutter: '3.24.0', channel: 'beta'),
      );
      expect(met.info, isNotNull);
      final unmet = detect(
        '3.24.0@beta',
        createFakeSdk(p.join(work.path, 'b'), flutter: '3.24.1', channel: 'beta'),
      );
      expect(
        unmet.problem,
        'The project pins Flutter 3.24.0 on the beta channel with FVM, but '
        'FVM does not have it installed, and the Flutter found through '
        'FLUTTER_ROOT is 3.24.1.',
      );
      expect(
        unmet.fixHint,
        'Run `fvm install 3.24.0@beta` in the project folder.',
      );
    });
  });
```

(d) `packages/appstein_engine/test/doctor/checks/fvm_check_test.dart`: add `import '../../support/fake_sdk.dart';`, then at the end of `main()`:

```dart
  test('a channel pin is described as a channel', () async {
    File(
      p.join(project.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "stable"}');
    fakeExecutable(tools, 'fvm');
    final result = await const FvmCheck().run(
      testContext(
        projectRoot: project.path,
        environment: fakeEnvironment({
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'Project pins the Flutter stable channel (.fvmrc)');
  });

  // Review Focus 3.
  test('a broken FVM settings file is named, since FVM itself will '
      'fail', () async {
    final home = tempDir().path;
    File(fvmSettingsFile(home))
      ..createSync(recursive: true)
      ..writeAsStringSync('{oops');
    File(
      p.join(project.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5"}');
    fakeExecutable(tools, 'fvm');
    final result = await const FvmCheck().run(
      testContext(
        projectRoot: project.path,
        environment: fakeEnvironment({
          ...fvmHomeVars(home),
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(
      result.details.last,
      startsWith(
        "FVM's settings file can't be used, and FVM stops with an error "
        'until it is fixed: ${fvmSettingsFile(home)} is not valid JSON: ',
      ),
    );
  });
```

(e) `packages/appstein_engine/test/doctor/checks/flutter_check_test.dart`, add at the end of `main()`:

```dart
  test('an SDK on the channel an unmet FVM pin names says why it is '
      'used', () async {
    final result = await check(foundSdk(unmetFvmPin: 'stable'));
    expect(result.status, CheckStatus.ok);
    expect(
      result.details,
      contains(
        'The project pins the Flutter stable channel with FVM; FVM does not '
        'have it, so this Flutter on that channel is used.',
      ),
    );
  });

  test("shows the SDK lookup's notes", () async {
    const note =
        'FLUTTER_ROOT is set to /nowhere, which is not a Flutter SDK, so it '
        'was ignored.';
    final result = await check(foundSdk(notes: const [note]));
    expect(result.details, contains(note));
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run (in `packages/appstein_engine`): `fvm dart test test/sdk test/doctor/checks/fvm_check_test.dart test/doctor/checks/flutter_check_test.dart`
Expected: FAIL to compile (`fvmPinChannel`, `SdkLocation.notes` and the other new names don't exist).

- [ ] **Step 4: Rewrite `fvm_pin.dart`**

Replace all of `packages/appstein_engine/lib/src/sdk/fvm_pin.dart` with the code below. (The byte order mark check compares a code unit, per the Global Constraints.)

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../host/host_environment.dart';

/// The channels an FVM pin can name. FVM 4 counts `main` as a channel; FVM 3
/// treats it as a release name, but installs it in the same place.
const fvmChannels = ['stable', 'beta', 'dev', 'master', 'main'];

/// A Flutter version a project pins with FVM, and the file that pins it.
final class FvmPin {
  /// Creates a pin.
  const FvmPin({
    required this.version,
    required this.configPath,
    required this.pinDirectory,
    this.cachePath,
  });

  /// The pin as written: a version such as `3.47.5`, a channel such as
  /// `stable`, a version on a channel such as `3.24.0@beta`, or a git
  /// reference. It is also the name of its folder in FVM's cache.
  final String version;

  /// The file the pin came from.
  final String configPath;

  /// The folder that holds the pin. It can be a parent of the project, and
  /// it is where FVM keeps the `.fvm/flutter_sdk` link for the pin.
  final String pinDirectory;

  /// The FVM cache folder the pin file sets with `cachePath`, as an absolute
  /// path (a relative one is taken from [pinDirectory]), or null when it sets
  /// none.
  final String? cachePath;

  /// The channel the pin names; see [fvmPinChannel].
  String? get channel => fvmPinChannel(version);

  /// The Flutter version to compare with an SDK's; see [fvmPinVersion].
  String? get flutterVersion => fvmPinVersion(version);
}

/// The channel [pin] names: `stable` for `stable`, `beta` for `3.24.0@beta`,
/// and null for a version or a git reference.
String? fvmPinChannel(String pin) =>
    fvmChannels.contains(pin) ? pin : _versionOnChannel(pin)?.channel;

/// The Flutter version [pin] names, to compare with an SDK's version:
/// `3.24.0` for `3.24.0@beta`, the pin itself for a version or a git
/// reference, and null for a bare channel such as `stable`.
String? fvmPinVersion(String pin) {
  if (fvmChannels.contains(pin)) return null;
  return _versionOnChannel(pin)?.version ?? pin;
}

/// How messages name what [pin] pins: `Flutter 3.47.5`,
/// `the Flutter stable channel`, or `Flutter 3.24.0 on the beta channel`.
String describeFvmPin(String pin) {
  if (fvmChannels.contains(pin)) return 'the Flutter $pin channel';
  final split = _versionOnChannel(pin);
  if (split != null) {
    return 'Flutter ${split.version} on the ${split.channel} channel';
  }
  return 'Flutter $pin';
}

/// The fix for a pin FVM doesn't have: `fvm install <pin>`, and for a bare
/// channel also `fvm use <channel>`, run in the project folder.
String fvmInstallHint(String pin) => fvmChannels.contains(pin)
    ? 'Run `fvm install $pin` or `fvm use $pin` in the project folder.'
    : 'Run `fvm install $pin` in the project folder.';

/// Reads the FVM pin that applies to [projectRoot]: `.fvmrc` (FVM 3) or
/// `.fvm/fvm_config.json` (FVM 2).
///
/// Like FVM, this looks in [projectRoot] and then in each parent folder up to
/// the filesystem root. The nearest folder with either file wins, so a
/// project inside a monorepo uses the repo's pin.
///
/// Returns null when no folder up the chain pins a version. Throws a
/// [FormatException] when the pin file it finds can't be read.
FvmPin? readFvmPin(String projectRoot) {
  var directory = p.absolute(projectRoot);
  while (true) {
    final pin = _readIn(directory);
    if (pin != null) return pin;
    final parent = p.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}

FvmPin? _readIn(String directory) {
  for (final (file, key) in [
    (File(p.join(directory, '.fvmrc')), 'flutter'),
    (File(p.join(directory, '.fvm', 'fvm_config.json')), 'flutterSdkVersion'),
  ]) {
    if (!file.existsSync()) continue;
    final data = _readJson(file);
    final version = data[key];
    if (version is! String || version.isEmpty) {
      throw FormatException('${file.path} has no "$key" version.');
    }
    final cache = data['cachePath'];
    return FvmPin(
      version: version,
      configPath: file.path,
      pinDirectory: directory,
      cachePath: cache is String && cache.isNotEmpty
          ? p.normalize(p.join(directory, cache))
          : null,
    );
  }
  return null;
}

/// Where FVM keeps its global settings, the file `fvm config` writes:
/// `%APPDATA%\fvm\.fvmrc` on Windows,
/// `~/Library/Application Support/fvm/.fvmrc` on macOS, and
/// `$XDG_CONFIG_HOME/fvm/.fvmrc` (or `~/.config/fvm/.fvmrc`) on Linux.
/// Null when the variable it needs isn't set.
String? fvmGlobalConfigPath(HostEnvironment environment) {
  final home = environment.homeDir;
  final String? folder = switch (environment.os) {
    HostOs.windows => environment.variable('APPDATA'),
    HostOs.macos =>
      home == null ? null : p.join(home, 'Library', 'Application Support'),
    HostOs.linux =>
      environment.variable('XDG_CONFIG_HOME') ??
          (home == null ? null : p.join(home, '.config')),
  };
  return folder == null ? null : p.join(folder, 'fvm', '.fvmrc');
}

/// What FVM's global settings file says, as far as Appstein uses it.
final class FvmGlobalConfig {
  /// Creates the result for the file at [path].
  const FvmGlobalConfig({required this.path, this.cachePath, this.problem});

  /// The settings file.
  final String path;

  /// The FVM cache folder it sets with `cachePath`, or null.
  final String? cachePath;

  /// Why the file can't be used, or null when it can. FVM itself stops with
  /// an error then; Appstein ignores the file.
  final String? problem;
}

/// Reads FVM's global settings file (see [fvmGlobalConfigPath]). Null when
/// there is no such file. Never throws: a file that can't be read or isn't
/// a JSON object gives a [FvmGlobalConfig.problem] instead.
FvmGlobalConfig? readFvmGlobalConfig(HostEnvironment environment) {
  final path = fvmGlobalConfigPath(environment);
  if (path == null) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  final Object? data;
  try {
    data = jsonDecode(_stripBom(file.readAsStringSync()));
  } on FileSystemException catch (error) {
    return FvmGlobalConfig(
      path: path,
      problem: 'Could not read $path: ${fileErrorReason(error)}',
    );
  } on FormatException catch (error) {
    return FvmGlobalConfig(
      path: path,
      problem: '$path is not valid JSON: ${error.message}',
    );
  }
  if (data is! Map<String, Object?>) {
    return FvmGlobalConfig(path: path, problem: '$path is not a JSON object.');
  }
  final cache = data['cachePath'];
  return FvmGlobalConfig(
    path: path,
    cachePath: cache is String && cache.isNotEmpty ? cache : null,
  );
}

/// The folder FVM keeps its Flutter versions in, for [pin], in FVM's own
/// order, highest first: the pin file's `cachePath`, `FVM_CACHE_PATH`,
/// `FVM_HOME` (FVM's older name for it), the global settings' `cachePath`,
/// then `fvm` in the home folder. Null when none applies.
String? fvmCacheFolder(FvmPin pin, HostEnvironment environment) {
  final home = environment.homeDir;
  return pin.cachePath ??
      environment.variable('FVM_CACHE_PATH') ??
      environment.variable('FVM_HOME') ??
      readFvmGlobalConfig(environment)?.cachePath ??
      (home == null ? null : p.join(home, 'fvm'));
}

/// `3.24.0@beta` split into its version and channel, or null when [pin]
/// isn't a version on a known channel. FVM rejects an unknown channel
/// after `@`; here such a pin is left whole, as a version.
({String version, String channel})? _versionOnChannel(String pin) {
  final at = pin.lastIndexOf('@');
  if (at <= 0) return null;
  final channel = pin.substring(at + 1);
  return fvmChannels.contains(channel)
      ? (version: pin.substring(0, at), channel: channel)
      : null;
}

/// The JSON object in [file]; empty when the JSON isn't an object. Throws a
/// [FormatException] when the file can't be read or isn't JSON.
Map<String, Object?> _readJson(File file) {
  final Object? data;
  try {
    data = jsonDecode(_stripBom(file.readAsStringSync()));
  } on FileSystemException catch (error) {
    throw FormatException(
      'Could not read ${file.path}: ${fileErrorReason(error)}',
    );
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  return data is Map<String, Object?> ? data : const {};
}

/// Windows PowerShell 5.1 writes a byte order mark that `jsonDecode` rejects.
String _stripBom(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
```

- [ ] **Step 5: Rewrite `flutter_sdk_locator.dart`**

Replace all of `packages/appstein_engine/lib/src/sdk/flutter_sdk_locator.dart` with:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';
import 'flutter_sdk_reader.dart';
import 'fvm_pin.dart';

/// Where a Flutter SDK was found.
enum SdkSource {
  /// Pinned by the project with FVM.
  fvm('FVM'),

  /// The FLUTTER_ROOT environment variable.
  flutterRoot('FLUTTER_ROOT'),

  /// The `flutter` command on PATH.
  path('PATH');

  const SdkSource(this.label);

  /// How the source is shown to people.
  final String label;
}

/// A Flutter SDK folder, and how it was found.
final class SdkLocation {
  /// Creates a location.
  const SdkLocation({
    required this.root,
    required this.source,
    this.fvmVersion,
    this.unmetFvmPin,
    this.notes = const [],
  });

  /// The SDK folder (the one that contains `bin/flutter`).
  final String root;

  /// How it was found.
  final SdkSource source;

  /// The version the project pins with FVM, when this SDK is the one FVM
  /// provides ([source] is [SdkSource.fvm]). It is null for an SDK found
  /// another way; see [unmetFvmPin] for a pin that such an SDK stands in for.
  final String? fvmVersion;

  /// The pin the project sets with FVM when FVM doesn't have it installed,
  /// so this SDK was found another way. `SdkInfo.fvmVersion` takes this
  /// value when the SDK meets the pin.
  final String? unmetFvmPin;

  /// Notes about what the lookup passed over on the way, such as a
  /// FLUTTER_ROOT that isn't an SDK. The Flutter check shows them.
  final List<String> notes;
}

/// The result of looking for a project's Flutter SDK: a location, or a
/// problem with a fix.
final class SdkLookup {
  /// The SDK was found.
  const SdkLookup.found(SdkLocation this.location)
    : problem = null,
      fixHint = null;

  /// No usable SDK. [problem] says why, and [fixHint] says what to do.
  const SdkLookup.failed(String this.problem, String this.fixHint)
    : location = null;

  /// The SDK, when found.
  final SdkLocation? location;

  /// Why no SDK was found.
  final String? problem;

  /// What the user should do about it.
  final String? fixHint;
}

/// Finds the Flutter SDK a project uses, in the same order a developer's own
/// tools would:
/// 1. the project's FVM pin (the `.fvm/flutter_sdk` link, else FVM's cache,
///    found by [fvmCacheFolder]);
/// 2. the FLUTTER_ROOT environment variable;
/// 3. the `flutter` command on PATH.
///
/// A pin states which Flutter the project needs, and FVM is only one way to
/// install it. When the project pins one that FVM doesn't have, steps 2 and
/// 3 still run, and an SDK they find records the unmet pin in
/// [SdkLocation.unmetFvmPin]; the caller then checks that the SDK meets it.
/// A version pin (`3.47.5`, or `3.24.0@beta`, whose version is `3.24.0`) is
/// met by that version; a channel pin (`stable`) by an SDK on that channel.
/// Only when neither step finds an SDK does the lookup fail, naming every
/// source it tried.
///
/// The pin is looked up in the project folder and its parents, as FVM does.
/// FLUTTER_ROOT is preferred over PATH even when its version differs from
/// the pin; the caller then reports the mismatch. A FLUTTER_ROOT that isn't
/// an SDK is skipped with a note: Flutter's own launcher scripts set it
/// themselves, so a wrong value can only mislead this lookup.
final class FlutterSdkLocator {
  /// Creates a locator for [environment].
  const FlutterSdkLocator(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  static const _installHint =
      'Install Flutter (https://docs.flutter.dev/get-started/install), or '
      'pin a version in the project with `fvm use <version>`.';

  /// Finds the SDK for [projectRoot], or for no project when it is null.
  SdkLookup locate({String? projectRoot}) {
    FvmPin? unmetPin;
    if (projectRoot != null) {
      final FvmPin? pin;
      try {
        pin = readFvmPin(projectRoot);
      } on FormatException catch (error) {
        return SdkLookup.failed(
          'Could not read the FVM pin: ${error.message}',
          'Fix the file, or run `fvm use <version>` again.',
        );
      }
      if (pin != null) {
        final fvm = _locateFvm(pin);
        if (fvm != null) return SdkLookup.found(fvm);
        unmetPin = pin;
      }
    }
    final unmetVersion = unmetPin?.version;
    final notes = <String>[];
    final flutterRoot = environment.variable('FLUTTER_ROOT');
    if (flutterRoot != null) {
      if (_isSdk(flutterRoot)) {
        return SdkLookup.found(
          SdkLocation(
            root: flutterRoot,
            source: SdkSource.flutterRoot,
            unmetFvmPin: unmetVersion,
          ),
        );
      }
      notes.add(
        'FLUTTER_ROOT is set to $flutterRoot, which is not a Flutter SDK, so '
        'it was ignored.',
      );
    }
    final flutter = findExecutable('flutter', environment);
    if (flutter != null) {
      // A snap, Homebrew or asdf shim doesn't resolve to an SDK folder.
      final root = p.dirname(p.dirname(resolveLinks(flutter)));
      if (_isSdk(root)) {
        return SdkLookup.found(
          SdkLocation(
            root: root,
            source: SdkSource.path,
            unmetFvmPin: unmetVersion,
            notes: notes,
          ),
        );
      }
    }
    final tried = [
      if (unmetPin != null)
        "the project's FVM pin (${describeFvmPin(unmetPin.version)}, from "
            '${unmetPin.configPath}, not installed)'
      else if (projectRoot != null)
        'no FVM pin in the project',
      if (flutterRoot == null)
        'FLUTTER_ROOT (not set)'
      else
        'FLUTTER_ROOT (set to $flutterRoot, not an SDK)',
      if (flutter == null)
        '`flutter` on PATH (not found)'
      else
        '`flutter` on PATH (found at $flutter, not inside an SDK)',
    ];
    return SdkLookup.failed(
      'No Flutter SDK found. Tried: ${tried.join(', ')}.',
      unmetPin != null ? fvmInstallHint(unmetPin.version) : _installHint,
    );
  }

  /// The SDK FVM provides for [pin], or null when FVM doesn't have it.
  ///
  /// The `.fvm/flutter_sdk` link next to the pin is used unless it is stale:
  /// `.fvm/` is usually gitignored while the pin is committed, so a pulled pin
  /// bump leaves the link on the old version. A link whose SDK reports a
  /// version other than the pin's is skipped, and FVM's cache is tried next.
  /// A link is kept when its SDK can't be read (so the caller reports it as
  /// not set up), and when the pin has no version to compare: a bare channel
  /// such as `stable`, or a git reference.
  SdkLocation? _locateFvm(FvmPin pin) {
    final link = p.join(pin.pinDirectory, '.fvm', 'flutter_sdk');
    if (_isSdk(link) && !_isStaleLink(link, pin)) {
      return SdkLocation(
        root: resolveLinks(link),
        source: SdkSource.fvm,
        fvmVersion: pin.version,
      );
    }
    final cache = fvmCacheFolder(pin, environment);
    if (cache != null) {
      final root = p.join(cache, 'versions', pin.version);
      if (_isSdk(root)) {
        return SdkLocation(
          root: root,
          source: SdkSource.fvm,
          fvmVersion: pin.version,
        );
      }
    }
    return null;
  }

  bool _isStaleLink(String link, FvmPin pin) {
    final version = pin.flutterVersion;
    if (version == null) return false;
    try {
      Version.parse(version);
    } on FormatException {
      return false;
    }
    try {
      return readSdkVersions(link).flutter != version;
    } on SdkNotSetUpException {
      return false;
    } on FormatException {
      return false;
    }
  }

  bool _isSdk(String root) {
    final flutter = environment.os == HostOs.windows
        ? 'flutter.bat'
        : 'flutter';
    return File(p.join(root, 'bin', flutter)).existsSync() &&
        Directory(p.join(root, 'packages', 'flutter')).existsSync();
  }
}
```

- [ ] **Step 6: The detector, FvmCheck and FlutterCheck**

(a) `packages/appstein_engine/lib/src/sdk/sdk_detector.dart`: add `import 'fvm_pin.dart';` after `import 'flutter_sdk_reader.dart';`, replace the `unmetPin` block with:

```dart
    final unmetPin = location.unmetFvmPin;
    if (unmetPin != null && !_meetsPin(unmetPin, versions)) {
      final found = fvmPinVersion(unmetPin) == null
          ? 'on the ${versions.channel} channel'
          : versions.flutter;
      return SdkDetection.failed(
        'The project pins ${describeFvmPin(unmetPin)} with FVM, but FVM does '
            'not have it installed, and the Flutter found through '
            '${location.source.label} is $found.',
        fvmInstallHint(unmetPin),
        location: location,
      );
    }
```

and add this method after `detect`:

```dart
  /// Whether an SDK with [versions] meets the FVM [pin]: the pin's version
  /// for a version pin, or its channel for a bare channel pin (`main` and
  /// `master` are one channel).
  static bool _meetsPin(String pin, FlutterSdkVersions versions) {
    final version = fvmPinVersion(pin);
    if (version != null) return versions.flutter == version;
    final channel = fvmPinChannel(pin)!;
    const trunk = {'main', 'master'};
    return versions.channel == channel ||
        (trunk.contains(channel) && trunk.contains(versions.channel));
  }
```

(b) Replace all of `packages/appstein_engine/lib/src/doctor/checks/fvm_check.dart` with:

```dart
import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../sdk/fvm_pin.dart';
import '../doctor_check.dart';

/// Checks FVM when the project pins a Flutter version with it.
final class FvmCheck implements DoctorCheck {
  /// Creates the check.
  const FvmCheck();

  @override
  String get id => 'doctor.fvm';

  @override
  String get title => 'FVM';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final fvm = findExecutable('fvm', context.environment);
    // The SDK lookup ignores a broken global settings file, but FVM itself
    // stops on it, so it is named here.
    final problem = readFvmGlobalConfig(context.environment)?.problem;
    final settingsLines = [
      if (problem != null)
        "FVM's settings file can't be used, and FVM stops with an error "
            'until it is fixed: $problem',
    ];
    final root = context.projectRoot;
    FvmPin? pin;
    if (root != null) {
      try {
        pin = readFvmPin(root);
      } on FormatException catch (error) {
        // The Flutter SDK check reports this as the error; a second error
        // here would count one broken file twice.
        return CheckResult.info(
          'The FVM pin could not be read; see the Flutter SDK line.',
          details: [error.message],
        );
      }
    }
    if (pin == null) {
      return fvm == null
          ? const CheckResult.skipped('Not used by this project.')
          : CheckResult.info(
              'FVM is installed; this project does not pin a Flutter version.',
              details: ['fvm: $fvm', ...settingsLines],
            );
    }
    final pinned = describeFvmPin(pin.version);
    if (fvm == null) {
      return CheckResult.warning(
        'The project pins $pinned with FVM, but `fvm` is not on PATH.',
        details: ['pin file: ${pin.configPath}', ...settingsLines],
        fixHint:
            'Install FVM (https://fvm.app) so `fvm flutter` and '
            '`fvm dart` work.',
      );
    }
    return CheckResult.ok(
      'Project pins $pinned (${p.basename(pin.configPath)})',
      details: ['pin file: ${pin.configPath}', 'fvm: $fvm', ...settingsLines],
    );
  }
}
```

(c) `packages/appstein_engine/lib/src/doctor/checks/flutter_check.dart`: add `import '../../sdk/fvm_pin.dart';` just before `import '../../sdk/supported_versions.dart';` (imports stay sorted), and replace the `details` list with:

```dart
    final details = [
      'Found through ${location.source.label}: ${location.root}',
      if (location.unmetFvmPin case final pin?)
        fvmPinVersion(pin) == null
            ? 'The project pins ${describeFvmPin(pin)} with FVM; FVM does '
                  'not have it, so this Flutter on that channel is used.'
            : 'The project pins $pin with FVM; FVM does not have it, so '
                  'this matching Flutter is used.',
      ...location.notes,
    ];
```

- [ ] **Step 7: Run the tests to see them pass**

Run (in `packages/appstein_engine`): `fvm dart test`
Expected: all pass. `fvm_pin_test.dart`'s `reads a .fvmrc that starts with a byte order mark` still passes with the code-unit check.

- [ ] **Step 8: Update the guide**

(a) `docs/guide/sdk-lookups.md`:
- Replace item 2 of `## The Flutter SDK` with:

```markdown
2. **The `FLUTTER_ROOT` environment variable.** It is used when it names an SDK folder, even when its version differs from the pin. The detector then reports the mismatch. When it is set but isn't an SDK, it is skipped with a note that the Flutter check shows. Flutter's own launcher scripts set `FLUTTER_ROOT` from where they live, so a wrong value can't confuse Flutter; it could only confuse this lookup, which is why doctor names it.
```

- After the sentence `A folder counts as an SDK when it has …`, add:

```markdown
**When nothing is found,** the failure names each source it tried and what it found there, such as ``No Flutter SDK found. Tried: no FVM pin in the project, FLUTTER_ROOT (not set), `flutter` on PATH (not found).`` Outside a project the FVM part is left out. With a pin FVM doesn't have, it names the pin (``the project's FVM pin (Flutter 3.46.0, from <file>, not installed)``), and the fix is the pin's `fvm install` command.
```

- In `### FVM pins`, after the bullet list, add:

```markdown
**What a pin names.** FVM accepts three kinds of value. `fvmPinChannel` and `fvmPinVersion` tell them apart:

| Pin | Meaning | An SDK meets it when |
|---|---|---|
| `stable`, `beta`, `dev`, `master`, `main` | A channel. FVM 4 counts `main` as a channel; FVM 3 treats it as a release name, but installs it in the same place | It is on that channel (`main` and `master` are one channel) |
| `3.24.0@beta` | A version on a channel | Its version is `3.24.0` |
| Anything else, such as `3.47.5` or a commit hash | A version, or a git reference | Its version is the whole value |

`describeFvmPin` puts a pin into words for messages ("Flutter 3.47.5", "the Flutter stable channel", "Flutter 3.24.0 on the beta channel"), and `fvmInstallHint` gives the fix: `fvm install <pin>`, and for a channel also `fvm use <channel>`.
```

- Replace item 2 of the `_locateFvm` list (`2. **FVM's cache:** …`) with:

```markdown
2. **FVM's cache:** `versions/<pin>` inside FVM's cache folder, so `versions/stable` for a channel and `versions/3.24.0@beta` for a version on a channel. `fvmCacheFolder` finds the cache folder as FVM does, highest first:
   1. `cachePath` in the pin file itself (a relative path is taken from the pin's folder);
   2. `FVM_CACHE_PATH`;
   3. `FVM_HOME`, FVM's older name for it;
   4. `cachePath` in FVM's global settings file, which `fvm config --cache-path` writes: `%APPDATA%\fvm\.fvmrc` on Windows, `~/Library/Application Support/fvm/.fvmrc` on macOS, and `$XDG_CONFIG_HOME/fvm/.fvmrc` (or `~/.config/fvm/.fvmrc`) on Linux;
   5. `fvm` in the home folder.

   A global settings file that can't be read or isn't valid JSON is ignored here. FVM itself stops with an error then, so the FVM check adds a line naming the file.
```

- Replace the last sentence of the `**A stale link is skipped.**` paragraph (from `The link is kept when` to the end) with: `The link is kept when its SDK can't be read yet (the detector then reports it as not set up), and when the pin has no version to compare: a bare channel such as \`stable\`, or a git reference.`
- Replace the three bullets of `### A pin FVM doesn't have` with:

```markdown
- **The SDK must meet the pin.** The detector checks it, as in the table above: the version for a version pin, the channel (from `flutter.version.json`) for a channel pin. A mismatch fails with "The project pins Flutter X with FVM, but FVM does not have it installed…", or "…pins the Flutter stable channel…, and the Flutter found through PATH is on the beta channel", with the pin's `fvm install` fix.
- **A match is accepted.** `SdkInfo.fvmVersion` is set to the pin, just as when FVM provides the SDK, and the Flutter check adds a detail line saying a matching Flutter (or, for a channel pin, a Flutter on that channel) is used in FVM's place.
- **With no other SDK at all,** the lookup fails, naming the pin among the sources it tried.
```

- Replace the whole `## Known gaps` section (heading, intro and list) with:

```markdown
## Where Appstein differs from Flutter

The lookups give Flutter's answer, and where Flutter does something surprising, the check's details explain it. A few differences are deliberate, or wait for a later slice:

- **An empty `ANDROID_HOME`.** Flutter counts a variable that is set as defined, even when it is empty, and stops the search there. `HostEnvironment` treats an empty variable as unset everywhere, so Appstein goes on to `ANDROID_SDK_ROOT` and the default folder.
- **`where` looks in the current folder first.** On Windows, Flutter finds `aapt` and `adb` with `where`, which searches the current folder before the PATH. `findAllExecutables` searches only the PATH.
- **A configured Android Studio on Windows.** Flutter reads `android-studio-dir` only after it has listed `%LOCALAPPDATA%\Google`, and skips the setting when that folder is missing. That is a Flutter bug in a rare case, and Appstein doesn't copy it: it always uses the configured install, because the setting is the user's explicit choice.
- **A configured Android Studio that doesn't exist.** Flutter stops every command with a tool error. The Java check reports it as an error, and the other checks still run.
- **Minimum versions.** Flutter reports an error when the platform or the build-tools are older than its Gradle plugin needs. Those minimums change with each Flutter version, so they come with the toolchain knowledge in slice 1b.2.
- **A broken FVM settings file.** FVM stops with an error when its global settings file isn't valid JSON. Appstein's lookup ignores the file, and the FVM check names it.
- **Folder order.** Where Flutter's answer depends on the order the file system lists a folder in (ties between Android Studio installs, platforms or build-tools), Appstein sorts the names, which gives Flutter's answer on NTFS and APFS, where listings are alphabetical.
```

(b) `docs/guide/doctor.md`, in the list after "A few behaviours the table doesn't show:", add after `**An unreadable FVM pin is counted once too.**`:

```markdown
- **The Flutter check shows the lookup's notes,** such as a `FLUTTER_ROOT` that was skipped because it isn't an SDK, and says when an SDK stands in for a pin FVM doesn't have.
- **The FVM check describes the pin.** A channel pin reads "Project pins the Flutter stable channel (.fvmrc)". When FVM's global settings file is broken, it adds a detail line, because FVM itself will stop with an error.
```

(c) `docs/guide/testing.md`:
- Replace the row for `testContext`, `foundSdk` with:

```markdown
| `testContext`, `foundSdk` | [`doctor_support.dart`](../../packages/appstein_engine/test/support/doctor_support.dart) | A `DoctorContext` for testing one check. By default: Flutter 3.47.5 found through PATH, an empty environment, and a runner that knows no commands. `foundSdk` also takes an unmet FVM pin and the lookup's notes |
```

- Replace the row for `createFakeSdk` with:

```markdown
| `createFakeSdk`, `fvmHomeVars`, `fvmSettingsFile` | [`fake_sdk.dart`](../../packages/appstein_engine/test/support/fake_sdk.dart) | The parts of a Flutter SDK folder Appstein reads, with version files that match Flutter 3.47.5's real ones. With `setUp: false` it leaves them out, like an SDK FVM downloaded but Flutter never ran. `fvmHomeVars` sets a home folder, and the folder FVM's global settings live under, for this OS; `fvmSettingsFile` says where that settings file then is |
```

(d) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.`

- [ ] **Step 9: Format, analyze and run everything in the engine and the CLI**

Run: `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, then `fvm dart test` in `packages/appstein_engine` and in `packages/appstein_cli`
Expected: clean; all pass.

- [ ] **Step 10: Hand back to the controller to commit**

Suggested message: `feat(sdk): classify FVM pins, find FVM's cache as FVM does, and name every source tried`

---

### Task 7: The `flutter doctor -v` cross-check, through `SdkDetector` (R12)

**Files:**
- Modify: `packages/appstein_engine/test/integration/doctor_real_environment_test.dart` (whole file)
- Modify: `docs/guide/testing.md` (`## Tests against the real machine`)

**Interfaces:**
- Consumes: Task 1's summary form `platform <p>, build-tools <b>` (the printer adds the title "Android SDK: "; ruling during execution); `readFvmPin(...).pinDirectory`; `SdkDetector.detect`; `Doctor.run(projectRoot:)`.

- [ ] **Step 1: Rewrite the integration tests**

Replace all of `packages/appstein_engine/test/integration/doctor_real_environment_test.dart` with:

```dart
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const runner = SystemProcessRunner();
  final environment = HostEnvironment.current();
  // The Appstein repo is the folder whose .fvmrc pins its Flutter. The tests
  // run from packages/appstein_engine, so the pin is found above them.
  final repoRoot = readFvmPin(Directory.current.path)?.pinDirectory;
  Future<RunResult>? flutterDoctorRun;

  /// The `flutter` launcher of the SDK doctor finds for the repo, so both
  /// sides use the same SDK. When there is none, the test fails in CI and is
  /// skipped elsewhere, and this returns null.
  String? repoFlutter() {
    if (repoRoot == null) {
      fail(
        'No .fvmrc above ${Directory.current.path}. Run the integration '
        'tests from the Appstein repo.',
      );
    }
    final detection = SdkDetector(environment).detect(projectRoot: repoRoot);
    final root = detection.location?.root;
    if (detection.info == null || root == null) {
      final reason =
          'doctor finds no usable Flutter SDK for the repo: '
          '${detection.problem}';
      if (environment.variable('CI') != null) fail(reason);
      markTestSkipped(reason);
      return null;
    }
    return p.join(root, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
  }

  /// `flutter doctor -v`, run once and shared by the tests that read it.
  Future<RunResult> flutterDoctor(String flutter) =>
      flutterDoctorRun ??= runner.run(flutter, [
        'doctor',
        '-v',
      ], timeout: const Duration(minutes: 5));

  /// Appstein's doctor for the repo.
  Future<DoctorReport> appsteinDoctor() =>
      Doctor(environment: environment, runner: runner).run(
        projectRoot: repoRoot,
      );

  CheckResult resultOf(DoctorReport report, String id) =>
      report.entries.singleWhere((entry) => entry.check.id == id).result;

  test('doctor reports the same Flutter version as flutter itself', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final machine = await runner.run(flutter, [
      '--version',
      '--machine',
    ], timeout: const Duration(minutes: 3));
    expect(machine.ok, isTrue, reason: machine.stderr);
    final start = machine.stdout.indexOf('{');
    if (start < 0) {
      fail(
        '`flutter --version --machine` printed no JSON in output: '
        '${machine.stdout}',
      );
    }
    final json =
        jsonDecode(machine.stdout.substring(start)) as Map<String, Object?>;

    final report = await appsteinDoctor();
    expect(
      resultOf(report, 'doctor.flutter').summary,
      contains(json['frameworkVersion']),
    );
    for (final entry in report.entries) {
      expect(
        entry.result.summary,
        isNot(startsWith('The check itself failed')),
        reason: entry.check.id,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // Compares Appstein's model of Flutter's JDK lookup with Flutter's own
  // answer on a real machine, where unit tests can only check the model.
  test('the Java check finds the JDK that flutter doctor -v reports', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final doctor = await flutterDoctor(flutter);
    final javaLine = RegExp(
      r'Java binary at: (.+)',
    ).firstMatch(doctor.stdout)?.group(1)?.trim();
    if (javaLine == null) {
      markTestSkipped('flutter doctor -v reports no Java binary');
      return;
    }

    final result = resultOf(await appsteinDoctor(), 'doctor.java');
    final pathLine = result.details
        .where((line) => line.startsWith('Path: '))
        .firstOrNull;
    expect(
      pathLine,
      isNotNull,
      reason: 'The Java check found no JDK: ${result.summary}',
    );
    final appsteinJdk = _jdkHome(pathLine!.substring('Path: '.length));
    expect(
      p.equals(appsteinJdk, _jdkHome(javaLine)),
      isTrue,
      reason: 'Appstein: $appsteinJdk\nflutter doctor -v: $javaLine',
    );
  }, timeout: const Timeout(Duration(minutes: 7)));

  // The same comparison for the Android SDK: which platform is newest, and
  // which build-tools Flutter pairs with it.
  test('the Android SDK check names the platform and build-tools flutter '
      'doctor -v reports', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final doctor = await flutterDoctor(flutter);
    final line = RegExp(
      r'Platform (\S+), build-tools (\S+)',
    ).firstMatch(doctor.stdout);
    if (line == null) {
      markTestSkipped('flutter doctor -v reports no Android SDK');
      return;
    }
    final result = resultOf(await appsteinDoctor(), 'doctor.android_sdk');
    expect(
      result.summary,
      contains('platform ${line[1]}, build-tools ${line[2]}'),
      reason: 'flutter doctor -v: ${line[0]}',
    );
  }, timeout: const Timeout(Duration(minutes: 7)));
}

/// [path] without a trailing `bin/java` or `bin/java.exe`.
String _jdkHome(String path) {
  final name = p.basename(path).toLowerCase();
  final parent = p.dirname(path);
  return (name == 'java' || name == 'java.exe') && p.basename(parent) == 'bin'
      ? p.dirname(parent)
      : path;
}
```

- [ ] **Step 2: Run them on the development machine**

Run (in `packages/appstein_engine`): `fvm dart test --run-skipped --tags integration`
Expected: 3 tests pass. The first uses `C:\Users\<you>\fvm\versions\3.47.5` (FVM's pin), not whatever `flutter` is first on the PATH. The Android test compares `platform android-37.0, build-tools 37.0.0-rc2`. If a test fails, report both sides' lines; don't loosen the comparison.

- [ ] **Step 3: Update the guide**

In `docs/guide/testing.md`, replace the `- **\`doctor_real_environment_test.dart\`** …` bullet, its two sub-bullets and the paragraph after them (`Both skip themselves when …`) with:

```markdown
- **`doctor_real_environment_test.dart`** in `packages/appstein_engine/test/integration/` runs the real doctor for the Appstein repo and compares it with Flutter's own answers. The repo is the folder whose `.fvmrc` the tests find above their working folder. The `flutter` they run is the one `SdkDetector` finds for the repo, so both sides describe the same SDK: FVM's pinned one on the development machine, and in CI the one CI installs, which must match the pin.
  - the Flutter version doctor reports must match `flutter --version --machine`, and no check may crash;
  - the JDK the Java check chooses must be the one `flutter doctor -v` names on its "Java binary at:" line;
  - the Android SDK check's summary must name the platform and build-tools on `flutter doctor -v`'s "Platform …, build-tools …" line.

  `flutter doctor -v` runs once, and its output is shared. When doctor finds no usable SDK for the repo, the tests skip themselves on a developer's machine but fail in CI (where the `CI` variable is set), because there it means CI itself is broken. The JDK test also skips when Flutter reports no Java, and the Android test when Flutter reports no Android SDK.
```

Run: `fvm dart run tool/check_guide.dart --since main`
Expected: `The guide check passed.`

- [ ] **Step 4: Format and analyze**

Run: `fvm dart format --output=none --set-exit-if-changed .`, then `fvm dart analyze --fatal-infos`
Expected: clean.

- [ ] **Step 5: Hand back to the controller to commit**

Suggested message: `test(integration): cross-check doctor against the repo's own Flutter, and compare platform and build-tools`

CI runs these tests on all three systems, so the change is proven when the slice's PR runs. The controller may push the branch and open a **draft** PR early only with the owner's OK.

---

### Task 8: A stricter stale rule for the guide (R13)

**Files:**
- Modify: `tool/src/generated_sections.dart` (a new function at the end)
- Modify: `tool/src/git_repo.dart` (a new method after `messagesSince`)
- Modify: `tool/src/guide_check.dart` (whole file)
- Modify: `test/generated_sections_test.dart`, `test/git_repo_test.dart`, `test/guide_check_test.dart`
- Modify: `docs/guide/docs-tooling.md` (`## Stale pages and \`Docs-Checked\``, `## Limits`)
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.md` (§19.6, one sentence, owner-approved wording in Step 7)

**Interfaces:**
- Produces: `String? stripGeneratedBodies(String markdown)`: the text with every generated section's body removed (the markers stay) and LF line endings; null when the markers are malformed. `String? GitRepo.fileAt(String rev, String path)`: the file's text at the merge base of `rev` and HEAD, or null when it didn't exist there. `checkStale`'s signature is unchanged.

- [ ] **Step 1: Write the failing tests**

(a) `test/generated_sections_test.dart`, add at the end of `main()`:

```dart
  group('stripGeneratedBodies', () {
    test('drops section bodies, keeps the markers and the text around them, '
        'and uses LF', () {
      expect(
        stripGeneratedBodies(
          '# T\r\n<!-- generated:alpha -->\r\nold\r\n\r\n'
          '<!-- /generated:alpha -->\r\nText\r\n',
        ),
        '# T\n<!-- generated:alpha -->\n<!-- /generated:alpha -->\nText\n',
      );
    });

    test('gives the same text before and after regenerating', () {
      const before =
          '# T\n\n<!-- generated:beta -->\nold\n<!-- /generated:beta -->\n';
      final after = regenerate(page, before, bodies).text;
      expect(after, isNot(before));
      expect(stripGeneratedBodies(after), stripGeneratedBodies(before));
    });

    test('leaves markers inside code fences alone', () {
      const markdown = '```text\n<!-- generated:alpha -->\nexample\n```\n';
      expect(stripGeneratedBodies(markdown), markdown);
    });

    test('accepts section names gen_docs does not know', () {
      expect(
        stripGeneratedBodies(
          '<!-- generated:gamma -->\nx\n<!-- /generated:gamma -->\n',
        ),
        '<!-- generated:gamma -->\n<!-- /generated:gamma -->\n',
      );
    });

    for (final (name, markdown) in [
      ('a section never closed', '<!-- generated:alpha -->\ntext\n'),
      ('an end marker without a start', '<!-- /generated:alpha -->\n'),
      (
        'mismatched markers',
        '<!-- generated:alpha -->\n<!-- /generated:beta -->\n',
      ),
      (
        'nested sections',
        '<!-- generated:alpha -->\n<!-- generated:beta -->\n'
            '<!-- /generated:alpha -->\n',
      ),
    ]) {
      test('is null for $name', () {
        expect(stripGeneratedBodies(markdown), isNull);
      });
    }
  });
```

(b) `test/git_repo_test.dart`, add at the end of `main()`:

```dart
  test('fileAt() reads a file at the merge base, or null when it was not '
      'there', () {
    writeFile(repo, 'docs/guide/a b ë.md', '# Spaced\r\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'spaced']);
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    writeFile(repo, 'docs/guide/README.md', '# Changed\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'change']);
    expect(git.fileAt('main', 'docs/guide/README.md'), '# Guide\n');
    expect(git.fileAt('main', 'docs/guide/a b ë.md'), '# Spaced\r\n');
    expect(git.fileAt('main', 'docs/guide/new.md'), isNull);
  });
```

(c) `test/guide_check_test.dart`, add at the end of `main()`:

```dart
  group('a page whose only change is a regenerated section', () {
    const page = 'docs/guide/README.md';
    const covers = '<!-- covers: tool/a.dart -->\n# G\n\n';
    const staleA =
        'tool/a.dart: Changed, but the page that explains it did not: '
        'docs/guide/README.md. Update the page, or if it is still right, add '
        'a commit trailer: Docs-Checked: README.md - <why it is still right>';

    String section(String body) =>
        '<!-- generated:facts -->\n\n$body\n\n<!-- /generated:facts -->\n';

    // Only the stale-page problems; the temp repo has none of Appstein's
    // generated facts, so the generated-section check complains too.
    Future<List<String>> stale(String repoRoot) async => [
      for (final problem in await checkGuide(repoRoot, since: 'main'))
        if (problem.message.startsWith('Changed, but') ||
            problem.file == 'commit message')
          '$problem',
    ];

    late Directory repo;

    setUp(() {
      repo = tempRepo();
      writeFile(repo, page, '$covers${section('old fact')}');
      writeFile(repo, 'tool/a.dart', '// a\n');
      runGit(repo, ['add', '.']);
      runGit(repo, ['commit', '-q', '-m', 'first']);
      runGit(repo, ['switch', '-q', '-c', 'feature']);
      writeFile(repo, 'tool/a.dart', '// a, changed\n');
    });

    test('does not clear the stale check', () async {
      writeFile(repo, page, '$covers${section('new fact')}');
      expect(await stale(repo.path), [staleA]);
    });

    // Review Focus 5.
    test('does not clear it with CRLF line endings either', () async {
      writeFile(
        repo,
        page,
        '$covers${section('new fact')}'.replaceAll('\n', '\r\n'),
      );
      expect(await stale(repo.path), [staleA]);
    });

    test('a hand-written change next to it clears it', () async {
      writeFile(
        repo,
        page,
        '$covers${section('new fact')}\nExplains the change.\n',
      );
      expect(await stale(repo.path), isEmpty);
    });

    test('a page with broken markers counts as changed', () async {
      writeFile(repo, page, '$covers<!-- generated:facts -->\n\nnew fact\n');
      expect(await stale(repo.path), isEmpty);
    });

    test('a page that is new since the merge base counts as changed', () async {
      writeFile(
        repo,
        'docs/guide/new.md',
        '<!-- covers: tool/a.dart -->\n# New\n',
      );
      expect(await stale(repo.path), isEmpty);
    });
  });
```

- [ ] **Step 2: Run the tests to see them fail**

Run (repo root): `fvm dart test test/generated_sections_test.dart test/git_repo_test.dart test/guide_check_test.dart`
Expected: FAIL to compile (`stripGeneratedBodies` and `fileAt` don't exist). With stubs, `does not clear the stale check` and its CRLF twin fail: they get `[]`, because today any diff counts.

- [ ] **Step 3: Add `stripGeneratedBodies`**

At the end of `tool/src/generated_sections.dart`, add:

```dart
/// [markdown] with the body of every generated section removed and LF line
/// endings, to compare two versions of a page for the stale-page check
/// (spec §19.6): a page whose only change is inside its sections strips to
/// the same text. The markers stay, and markers inside code fences are left
/// alone, as in [regenerate]. Any section name is accepted. Null when the
/// markers are malformed, because the sections can't be told apart from
/// the hand-written text then.
String? stripGeneratedBodies(String markdown) {
  final out = <String>[];
  final fences = FenceTracker();
  String? open;
  for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final trimmed = line.trim();
    if (open == null) {
      out.add(line);
      if (fences.next(line) != FenceLine.prose) continue;
      final start = _start.firstMatch(trimmed);
      if (start != null) {
        open = start.group(1);
      } else if (_end.hasMatch(trimmed)) {
        return null;
      }
      continue;
    }
    final end = _end.firstMatch(trimmed);
    if (end == null) {
      if (_start.hasMatch(trimmed)) return null;
      continue;
    }
    if (end.group(1) != open) return null;
    out.add(line);
    open = null;
  }
  return open == null ? out.join('\n') : null;
}
```

- [ ] **Step 4: Add `GitRepo.fileAt`**

In `tool/src/git_repo.dart`, add after `messagesSince`:

```dart
  /// The text of [path] (repo-relative, with forward slashes) at the merge
  /// base of [rev] and HEAD, as git stores it, or null when the file didn't
  /// exist there.
  String? fileAt(String rev, String path) {
    final spec = '${_mergeBase(rev)}:$path';
    if (_run(['cat-file', '-e', spec]).exitCode != 0) return null;
    return _git(['cat-file', 'blob', spec]);
  }
```

- [ ] **Step 5: Filter pages in `guide_check.dart`**

Replace all of `tool/src/guide_check.dart` with:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'coverage.dart';
import 'generated_docs.dart';
import 'generated_sections.dart';
import 'git_repo.dart';
import 'guide_checker.dart';
import 'stale_check.dart';

/// Runs every developer guide check (spec §19.6) on the repo at [repoRoot]:
/// - links and repo paths in the guide and package READMEs;
/// - every guide page linked from the start page;
/// - the coverage map;
/// - generated sections up to date;
/// - with [since], the stale-page check against the merge base of [since]
///   and HEAD. A guide page counts as changed only when its hand-written
///   text changed: a page whose only change is inside generated sections
///   doesn't explain anything new.
///
/// Throws [GitException] when [repoRoot] isn't a git repo.
Future<List<GuideProblem>> checkGuide(String repoRoot, {String? since}) async {
  final git = GitRepo(repoRoot);
  final pages = guidePages(repoRoot);
  final problems = <GuideProblem>[
    for (final file in guideFiles(repoRoot)) ...checkMarkdown(repoRoot, file),
    ...checkLinked(repoRoot, pages),
  ];
  final covers = readCoverMap(repoRoot, pages);
  problems
    ..addAll(covers.problems)
    ..addAll(checkCoverage(covers.map, git.files()));
  if (since != null) {
    if (git.hasCommit(since)) {
      problems.addAll(
        checkStale(
          map: covers.map,
          changed: [
            for (final file in git.changedSince(since))
              if (!_onlyGeneratedChanged(repoRoot, git, since, file, covers.map))
                file,
          ],
          messages: git.messagesSince(since),
        ),
      );
    } else {
      problems.add(GuideProblem('--since', null, '$since is not a commit.'));
    }
  }
  final generated = await regenerateGuide(repoRoot, pages, write: false);
  problems
    ..addAll(generated.problems)
    ..addAll([
      for (final page in generated.changedPages)
        GuideProblem(
          page,
          null,
          'Generated sections are out of date. Run: '
          'fvm dart run tool/gen_docs.dart',
        ),
    ]);
  return problems;
}

/// Whether [file] is a guide page whose text is the same as at the merge
/// base of [since], once generated section bodies are left out and line
/// endings are made LF. Such a page changed only where `gen_docs` writes.
/// A page that is new, deleted, unreadable or has broken markers counts as
/// changed.
bool _onlyGeneratedChanged(
  String repoRoot,
  GitRepo git,
  String since,
  String file,
  CoverMap map,
) {
  if (!map.pages.containsKey(file)) return false;
  final current = File(p.joinAll([repoRoot, ...file.split('/')]));
  if (!current.existsSync()) return false;
  final base = git.fileAt(since, file);
  if (base == null) return false;
  final String text;
  try {
    text = current.readAsStringSync();
  } on FileSystemException {
    return false;
  }
  final stripped = stripGeneratedBodies(text);
  return stripped != null && stripped == stripGeneratedBodies(base);
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run (repo root): `fvm dart test test`
Expected: all pass, including the existing `the stale-page check, end to end` group.

- [ ] **Step 7: Update the guide**

In `docs/guide/docs-tooling.md`:

(a) In `## Stale pages and \`Docs-Checked\``, add after the `- **What counts as changed:** …` bullet:

```markdown
- **A guide page must change in its own words.** A page counts as changed only when its text differs from the merge base's copy with every generated section body left out and line endings ignored. So a page that only `gen_docs` rewrote doesn't clear the check for the files it covers: a regenerated fact isn't a sign that someone read the hand-written text around it. A page that is new since the merge base, deleted, unreadable, or has broken markers counts as changed. `stripGeneratedBodies` in [`generated_sections.dart`](../../tool/src/generated_sections.dart) removes the bodies, and `GitRepo.fileAt` reads the merge base's copy.
```

(b) In `## Limits`, delete the bullet that starts `- **A regenerated section counts as the page changing.**`.

(c) **Spec §19.6 (owner-approved wording, 2026-09-30).** In `docs/superpowers/specs/2026-09-29-appstein-design.md`, in the `- **Code changes come with their page.**` bullet, replace `In CI, the check fails when a change edits a covered file but none of the pages covering it.` with, verbatim:

```markdown
In CI, the check fails when a change edits a covered file but not the hand-written text of any page covering it (a regenerated section alone doesn't count).
```

Then check `docs/superpowers/specs/2026-09-29-appstein-design.html`: it has no sentence about how the stale check decides a page changed, so it doesn't change. Confirm that and change nothing there.

(d) Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.` This run is the new rule's first real test: every page this slice changed has hand-written changes, so it must still pass. If it names a file, a task edited only a generated section of that file's page; fix the page, not the rule.

- [ ] **Step 8: Format and analyze**

Run: `fvm dart format --output=none --set-exit-if-changed .`, then `fvm dart analyze --fatal-infos`
Expected: clean.

- [ ] **Step 9: Hand back to the controller to commit**

Suggested message: `feat(tool): a page counts as changed only when its hand-written text changed`

---

### Task 9 (controller): verify, record, update the graph, finish

The controller does this task: it runs graphify's LLM extraction, edits `AGENTS.md` and memory, and commits.

- [ ] **Step 1: Full verification**

Run, from the repo root: `fvm dart test test`; `fvm dart test` in each of `packages/appstein_protocol`, `packages/appstein_engine`, `packages/appstein_cli`, `packages/appstein_lints`; `fvm dart test --run-skipped --tags integration` in `packages/appstein_engine`; `fvm dart format --output=none --set-exit-if-changed .`; `fvm dart analyze --fatal-infos`; `fvm dart run tool/gen_docs.dart --check`; `fvm dart run tool/check_guide.dart --since main`.
Expected: all green.

- [ ] **Step 2: Compare with Flutter on the development machine**

Run: `fvm dart run packages/appstein_cli/bin/appstein.dart doctor` and `fvm flutter doctor -v`.
Expected: the same Flutter version, the same JDK (`Path:` and "Java binary at:"), and the same platform and build-tools (`platform android-37.0, build-tools 37.0.0-rc2`). Record both outputs' relevant lines in the notes below.

- [ ] **Step 3: Check the guide's leftovers**

Search `docs/guide/` for `Known gaps`, `prefers the newest stable`, `not searched`, `skipped silently` and `setting isn't read`. Expected: no matches (Tasks 1, 4 and 6 replaced them). Fix any leftover in the page, then re-run `check_guide`.

- [ ] **Step 4: Record the plan's notes and the phase**

Add a `## Notes from execution` section at the end of this plan: the rulings made during execution, anything that differed from the plan, and Step 2's comparison. In `AGENTS.md`, replace the last sentence of **Current phase**, `Next: plan slice 1b.`, with: `1b.1 made \`doctor\` agree with \`flutter doctor -v\` on every OS: build-tools and platforms, the aapt/adb fallback, macOS Android Studio discovery, FVM channel pins and cache, file error reasons, and a stricter stale-page rule (plan: docs/superpowers/plans/2026-09-30-slice-1b1-sdk-gaps.md). Next: plan slice 1b.2, the knowledge layer.`, and change `M1 slices 1a, 1a.1 and 1a.2 are complete.` to `M1 slices 1a, 1a.1, 1a.2 and 1b.1 are complete.` Commit with the owner's approval.

- [ ] **Step 5: Update the graph until the check is silent**

Run `/graphify . --update`, relabel the communities, then run the graph check (PowerShell: `& (Get-Content graphify-out/.graphify_python) tool/check_graph.py`).
Expected: `graphify: the graph is current (<n> docs checked).` Repeat after any later edit; the check must still report nothing when the slice merges.

- [ ] **Step 6: Memory**

Record slice 1b.1 as done in the project memory (with the merge commit once merged), and point the index at slice 1b.2 as next.

- [ ] **Step 7: Finish the branch**

Use superpowers:finishing-a-development-branch. Push and open a PR only with the owner's OK. CI runs the integration tests on Windows, macOS and Linux; the Android SDK comparison is new there, so read its result on each OS before merging.

## Carried to later slices

- **`ANDROID_HOME=""`** (and `ANDROID_SDK_ROOT=""`): Flutter treats a set-but-empty variable as defined and stops its search; `HostEnvironment` treats it as unset everywhere. Changing it touches every caller of `variable()`, so it needs its own decision. Documented in sdk-lookups' "Where Appstein differs from Flutter".
- **Flutter's minimum platform and build-tools versions** (`compileSdkVersionInt`, `minBuildToolsVersion` in `gradle_utils.dart`): slice 1b.2's `toolchain.json` carries these per Flutter version; the Android SDK check can then report them as Flutter does.
- **`where` searching the current folder first** on Windows: not copied; documented.
- **Flutter's Windows early return** that drops a configured Android Studio when `%LOCALAPPDATA%\Google` is missing: a Flutter bug, not copied; documented.
- **Flutter's other Android toolchain findings** (found by the final review): a missing `cmdline-tools` component (an error in Flutter), a licenses-only SDK, spaces in the SDK path, a missing `android.jar` or an `aapt` that can't run in the paired platform/build-tools. Documented under "Where Appstein differs from Flutter"; add them to the Android SDK check alongside 1b.2's toolchain facts.
- **FVM edge cases** (documented, not handled): `FVM_CACHE_PATH=""` (FVM uses a relative `versions` folder), FVM 4 fork pins (`fork/3.24.0`, forked `x@channel` cached without `@channel`), a relative global `cachePath`.
- **Parked review minors:** `LenientVersion` has no `==`/`hashCode` (unused today); the Android SDK warning's fix hint is generic for a build-tools entry that is a file; a JetBrains Toolbox launcher is detected by its plist key anywhere, not only in the top-level dictionary (documented); `studioInstalledReason` checks only the top level of `/Applications`; `fileAt` spawns up to four git processes per changed page; test gaps noted in the reviews (duplicate PATH entries, `cmdline-tools` adb precedence, an `x@channel` stale link, a `main` pin, a non-object global FVM settings file).

## Notes from execution

Built subagent-driven, quick mode (as 1a.2), on 2026-09-30 and 2026-10-01.

- **Order:** Task 8 ran in parallel with Task 1 (disjoint files). Task 5 ran before Task 4, because Task 4 rewrote the file Task 3 changed and waited for Task 3's review. Reviews ran alongside the next implementer. Task 7's review and Task 4's fix-round re-review were folded into the final review (Opus).
- **Controller ruling, Task 1:** `AndroidSdkCheck`'s summary is `platform <p>, build-tools <b>`, without the plan's `Android SDK: ` prefix, because the doctor printer already prints the check's title (the plan's strings would have printed it twice). The code blocks in Task 1 above still show the prefix.
- **Owner ruling, Task 4 (2026-09-30):** when `android-studio-dir` names `.../X.app/Contents`, match Flutter: its `latestValid` compares the configured path unstripped, so that Studio is an ordinary candidate and the newest valid one wins; Appstein says so in a note. This replaced R5's "only it counts" for that case (R5 was based on incomplete research). Also matched Flutter: `mdfind`'s output is used whatever its exit code, and `plutil` falls back to reading the file only when it can't start.
- **Owner ruling, final review (2026-10-01):** folder listings keep the file system's order, exactly as Flutter reads them. This replaced R1's "ties prefer the name that sorts first", which rested on a false premise (only NTFS lists folders alphabetically; APFS and ext4 don't). Tie tests now derive the expected winner from the real listing.
- **Rejected review finding:** "invalid UTF-8 throws `FormatException`" (Tasks 1 and 8). In Dart, `readAsStringSync` throws `FileSystemException` for undecodable bytes, which the code already catches.
- **Reviews:** every task Approved. Task 4 needed one fix round (Opus review: the `Contents` case and six minors). The final review found no Critical issues; its fix wave (APFS wording, file-system order, the differences from Flutter listed in sdk-lookups.md, `describeFvmPin` in the Flutter check, the appstein.yaml hint) passed a scoped re-review.
- **Verification on the development machine (Windows):** engine 234 tests (1 skipped), repo tools 118, CLI 15, protocol 14, lints 17, and the 3 real-machine integration tests all pass. `appstein doctor` and `flutter doctor -v` agree: Flutter 3.47.5 on stable through FVM; the JDK at `C:\Program Files\Android\Android Studio1\jbr`; `platform android-37.0, build-tools 37.0.0-rc2` (before this slice doctor said build-tools 36.1.0).
- **Still to prove in CI:** the Android platform/build-tools cross-check on Linux and macOS runners, where tied platform folders (`android-36-extNN`) and non-alphabetical listings exist.