<!-- covers:
packages/appstein_engine/lib/src/doctor/**
packages/appstein_engine/lib/src/project/**
-->

# `appstein doctor`

## What it is for

`appstein doctor` checks the machine and the project, and says how to fix each problem it finds. Most Appstein failures are environment problems, so doctor is the first thing to run when something goes wrong. What it should check is decided in [spec §5.3](../superpowers/specs/2026-09-29-appstein-design.md#53-commands). This page explains how the code does it.

The code lives in `packages/appstein_engine/lib/src/doctor/`. The command-line side (the `doctor` command, printing and the exit code) is in [cli](cli.md).

## How a run works

`Doctor.run` in [`doctor.dart`](../../packages/appstein_engine/lib/src/doctor/doctor.dart) does four things:

1. **Detects the Flutter SDK once.** It calls `SdkDetector.detect` for the project, and puts the answer in a `DoctorContext` with the `HostEnvironment`, the `ProcessRunner` and the project folder. Every check reads the SDK from the context, so the lookup isn't repeated and every check agrees on which Flutter is in use. See [sdk-lookups](sdk-lookups.md).
2. **Runs every check at the same time.** The checks start together (`Future.wait`), so their external tools run side by side and the slowest check sets the run time.
3. **Keeps the results in check order.** However the checks finish, the `DoctorReport` lists them in the order of the check list, so the output is stable.
4. **Turns a crashing check into an error result.** If a check throws, the run doesn't stop: that check's result becomes an error, "The check itself failed: …", with the fix "This is a bug in Appstein. Please report it."

`DoctorReport.hasErrors` is true when any result is an error. The `doctor` command turns that into exit code `1`; warnings don't change the exit code.

The types:

| Type | File | What it is |
|---|---|---|
| `DoctorCheck` | [`doctor_check.dart`](../../packages/appstein_engine/lib/src/doctor/doctor_check.dart) | One check: a stable `id` (such as `doctor.flutter`), a `title` shown to people, and `run(context)` |
| `DoctorContext` | `doctor_check.dart` | What a check may look at: `environment`, `runner`, `projectRoot` (null outside a project) and `sdk` |
| `CheckResult` | `doctor_check.dart` | What a check found: a status, a one-line summary, detail lines and a fix hint |
| `Doctor` | `doctor.dart` | Runs the checks; `defaultDoctorChecks()` in the same file lists them |
| `DoctorEntry`, `DoctorReport` | `doctor.dart` | A check paired with its result, and the list of those for one run |

## Results

`CheckStatus` has five values:

| Status | Printed as | Meaning |
|---|---|---|
| `ok` | `[ok]` | Everything is fine |
| `info` | `[info]` | Worth knowing, nothing to fix |
| `warning` | `[warn]` | Something may cause trouble later |
| `error` | `[error]` | Something Appstein or Flutter needs is broken or missing. Makes the exit code `1` |
| `skipped` | `[skip]` | The check doesn't apply here, for example Xcode on Windows |

- **The summary** is one line saying what was found, such as `Flutter 3.47.5 (stable)`.
- **`details`** are extra lines that explain the summary: the path a tool was found at, the file a pin came from, or why an install was passed over. They are printed indented under the summary.
- **A fix hint appears only on a warning or an error.** The `ok`, `info` and `skipped` constructors don't take one, and the printer shows `Fix:` only for those two statuses. A fix hint says what to do, often as the exact command.

## The checks

This table is generated from `defaultDoctorChecks()`, in the order doctor shows them. Each row's text is the first paragraph of the check's `///` comment.

<!-- generated:doctor-checks -->

| # | ID | Shown as | What it checks | Code |
|---|---|---|---|---|
| 1 | `doctor.flutter` | Flutter SDK | Checks that the project's Flutter SDK is found and supported. | [flutter_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/flutter_check.dart) |
| 2 | `doctor.dart` | Dart SDK | Reports the Dart SDK bundled with Flutter, and notes (as information, not a warning) when the `dart` on PATH belongs to a different SDK. | [dart_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/dart_check.dart) |
| 3 | `doctor.fvm` | FVM | Checks FVM when the project pins a Flutter version with it. | [fvm_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/fvm_check.dart) |
| 4 | `doctor.java` | JDK used by Flutter | Checks the JDK Flutter actually uses for Android builds, and whether JAVA_HOME names a JDK of another version. | [java_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/java_check.dart) |
| 5 | `doctor.android_sdk` | Android SDK | Checks the Android SDK as Flutter reads it: the newest platform, the build-tools Flutter pairs with it, `zipalign` in those build-tools for the 16 KB page-size check, and `platform-tools`. | [android_sdk_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/android_sdk_check.dart) |
| 6 | `doctor.xcode` | Xcode | Checks Xcode on macOS. App Store uploads need Xcode 26 or newer. | [xcode_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/xcode_check.dart) |
| 7 | `doctor.cocoapods` | CocoaPods | Checks CocoaPods on macOS. Swift Package Manager is the default now, but plugins without SwiftPM support still need CocoaPods. | [cocoapods_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/cocoapods_check.dart) |
| 8 | `doctor.git` | git | git: the planned `create` and `upgrade` commands need it, to propose the first commit and to refuse a dirty tree (spec §13). | [tool_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/tool_check.dart) |
| 9 | `doctor.ripgrep` | ripgrep | ripgrep: the Dart MCP server's package search needs it. | [tool_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/tool_check.dart) |
| 10 | `doctor.agents` | Agent CLIs | Checks which supported agent CLIs are installed. It only runs `--version`; Appstein never touches agent logins (spec §4, principle 6). | [agents_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/agents_check.dart) |
| 11 | `doctor.appstein_path` | appstein on PATH | Checks that agent hooks can find the `appstein` command (spec §5.3). | [appstein_path_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/appstein_path_check.dart) |
| 12 | `doctor.project` | Project | Checks the project: its `appstein.yaml` and Dart language version. | [project_check.dart](../../packages/appstein_engine/lib/src/doctor/checks/project_check.dart) |

<!-- /generated:doctor-checks -->

A few behaviours the table doesn't show:

- **Checks that need Flutter skip without it.** When SDK detection failed, the Flutter check reports the problem as the error, and the Dart check is skipped ("Needs a Flutter SDK"). One missing SDK is counted once.
- **An unreadable FVM pin is counted once too.** The Flutter check reports it as an error, and the FVM check only notes it as info.
- **The Flutter check shows the lookup's notes,** such as a `FLUTTER_ROOT` that was skipped because it isn't an SDK, and says when an SDK stands in for a pin FVM doesn't have.
- **The FVM check describes the pin.** A channel pin reads "Project pins the Flutter stable channel (.fvmrc)". When FVM's global settings file is broken, it adds a detail line, because FVM itself will stop with an error.
- **Xcode and CocoaPods are skipped outside macOS.**
- **The Java check names what Flutter passed over.** Whether or not a JDK is found, each Android Studio install Flutter would skip gets a detail line saying why. An empty `jdk-dir` setting, or one that isn't text, is an error with the exact `flutter config` command to fix it, because Flutter can't use it. The check also compares the JDK with JAVA_HOME: another JDK of the same major version is info, a different version is a warning, because Gradle run outside Flutter uses JAVA_HOME. See [sdk-lookups](sdk-lookups.md#the-jdk).
- **The Android SDK check names the pair Flutter uses.** Its summary gives the newest platform and the build-tools Flutter pairs with it, previews included, in the words `flutter doctor -v` prints (`platform android-37.0, build-tools 37.0.0-rc2`). Platform folders Flutter ignores are listed in its details. See [sdk-lookups](sdk-lookups.md#platforms-and-build-tools). When more than one `adb` is found (the SDK's own and others on the PATH), it lists them all, as `flutter doctor -v` does, without changing the status.
- **The `appstein` on PATH check reads the registry on Windows.** It compares the terminal's PATH with the user and system PATH saved in the registry (`reg query`), because an agent started from elsewhere gets the saved one.

## Finding the project

Which project doctor checks is decided before the doctor runs. The CLI's `resolveProjectRoot` takes `--project`, or else calls `findProjectRoot` from [`project_locator.dart`](../../packages/appstein_engine/lib/src/project/project_locator.dart): the nearest folder, at or above the working folder, that contains `pubspec.yaml`. With no `--project` and no such folder, the project is null. See [cli](cli.md#global-options).

`ProjectCheck`, in [`project_check.dart`](../../packages/appstein_engine/lib/src/doctor/checks/project_check.dart), reports on that project:

| Situation | Result |
|---|---|
| No project | `skipped`: "Not inside a Dart or Flutter project." |
| `pubspec.yaml` can't be read | `error`, with the file and the reason |
| `appstein.yaml` can't be read, or its YAML error has no position | `error`, with the reason; the fix says to make it a readable UTF-8 file with valid YAML |
| `appstein.yaml` is invalid | `error`, saying where: the file, and the line and column when known |
| No `appstein.yaml` | `info`: the project isn't set up with Appstein yet |
| A valid `appstein.yaml` | `ok`, with the stack, the platforms and the Dart language version |

**An invalid `appstein.yaml` is a check error, so `doctor` exits `1`, not `3`.** `ProjectCheck` catches the `ConfigException` from `loadConfig` and turns it into a result. That way doctor can still show every other check. [config](config.md) explains the loader and its errors.

The Dart language version comes from the lower bound of the SDK constraint in `pubspec.yaml`; [sdk-lookups](sdk-lookups.md#versions) explains why it matters.

## Shared helpers

[`check_helpers.dart`](../../packages/appstein_engine/lib/src/doctor/check_helpers.dart) holds one function, `firstLine`: the first non-empty line of a tool's output, trimmed. Tools usually print their version there, so the Java, Xcode, CocoaPods, agent and tool checks use it to show a version or an error message in one line.

Everything else a check needs comes from the engine's other folders: `findExecutable` and the `ProcessRunner` ([running-tools](running-tools.md)), and the SDK, JDK and Android SDK lookups ([sdk-lookups](sdk-lookups.md)).

## A rule the checks follow

**When doctor reports on Flutter's toolchain, it gives Flutter's own answer, not an opinion.** The Flutter, JDK and Android SDK checks report the SDK, JDK and Android SDK that Flutter itself would use, found the way Flutter finds them. If doctor said "your JDK is fine" while Flutter used a different, broken one, doctor would be worse than useless. [sdk-lookups](sdk-lookups.md) explains each lookup.

In slice 1a, doctor reported the owner's JDK as broken while Flutter used a working one, because our model of Flutter's JDK lookup was wrong. The unit tests passed, since they encoded the same wrong model; only comparing with `flutter doctor -v` on the real machine showed it, and an integration test now makes that comparison ([testing](testing.md#tests-against-the-real-machine)).

## Adding a check

Follow [How to: add a doctor check](how-to/add-a-doctor-check.md).
