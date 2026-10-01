<!-- covers: packages/appstein_engine/lib/src/toolchain/** -->

# The toolchain matrix

`.appstein/platform/toolchain.json` tells agents which native versions work with the installed Flutter: Gradle, AGP, Kotlin, Java, NDK, the SDK levels, and the iOS and macOS deployment targets (spec §12). Agents are told never to "upgrade to latest", so these numbers have to be right for *this* SDK.

## Where the numbers come from

Appstein reads them from the installed Flutter SDK's own files, the same files Flutter's tools use:

| SDK file | What it gives | Parsed by |
|---|---|---|
| `flutter_tools/lib/src/android/gradle_utils.dart` | Template versions (`flutter create`), Flutter's minimum platform, build-tools and Java, the newest versions Flutter knows, and the Java↔Gradle and AGP↔Java lists | [`parseGradleUtils`](../../packages/appstein_engine/lib/src/toolchain/gradle_utils_parser.dart) |
| `flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt` | The versions below which Flutter's Gradle plugin warns (`warnBelow`) or fails the build (`errorBelow`): Gradle, AGP, KGP, Java, minSdk | [`parseGradlePluginChecks`](../../packages/appstein_engine/lib/src/toolchain/gradle_plugin_checks_parser.dart) |
| `flutter_tools/templates/app/ios.tmpl/Runner.xcodeproj/project.pbxproj.tmpl` and the `macos.tmpl` one | `IPHONEOS_DEPLOYMENT_TARGET` and `MACOSX_DEPLOYMENT_TARGET` | [`parseDeploymentTarget`](../../packages/appstein_engine/lib/src/toolchain/xcode_template_parser.dart) |

The paths are listed once, in [`ToolchainFiles`](../../packages/appstein_engine/lib/src/toolchain/toolchain_files.dart).

**Why the analyzer's parser for `gradle_utils.dart`.** Flutter writes these values as Dart code. Some are plain strings (`'9.3.1'`), some are interpolations of other constants (`'$compileSdkVersionInt'`), some are calls (`Version(28, 0, 3)`), and the compatibility lists point at other constants (`agpMax: maxKnownAndSupportedAgpVersion`). `parseString` from `package:analyzer` gives the exact syntax tree, whatever the formatting, comments or line endings. The parser then evaluates only the shapes it knows. Anything else raises a `ToolchainParseException` naming the declaration, rather than a guess.

**The Kotlin file** is read with a regular expression for its ten `val warn…Version` and `val error…Version` lines. Both supported minors write them the same way.

Windows checkouts of Flutter with CRLF endings parse the same as LF ones, because the analyzer's parser and the regular expressions accept `\r\n`.

## When the SDK's files can't be read

[`readToolchain`](../../packages/appstein_engine/lib/src/toolchain/toolchain_reader.dart) reads three parts (Android, iOS, macOS) separately. For a part that fails, because a file is missing or its shape changed in a new Flutter:
- the part comes from the toolchain matrix in the newest curated notes file at or below the SDK version (see [knowledge-store](knowledge-store.md#the-curated-notes));
- each part records its `source` (`sdk` or `notes`);
- a sentence in `fallbacks` says what failed (`toolchain.fallback`, info);
- with no such notes file, the part is null, with its own sentence.

`readToolchain` never throws for a missing or reshaped file.

A test keeps each notes file's matrix equal to Flutter's files for that version, so a fallback for a version with a notes file gives the numbers Flutter uses. An SDK newer than the newest notes file gets the newest notes' numbers, and its notes coverage is reported as partial. An SDK that reports no version (`0.0.0-unknown`, from a fork or shallow clone) has no minor version, so it gets no notes and partial coverage.

## Tests and fixtures

`packages/appstein_engine/test/fixtures/flutter_sdk/<version>/` holds the four files of Flutter 3.44.9 and 3.47.5, downloaded from the flutter/flutter repo (BSD licence, header kept). Each ends in `.fixture`, so the analyzer doesn't compile them and graphify doesn't index them. `addToolchainFiles` copies them into a fake SDK under their real names.

Real SDKs are covered by `sync_real_environment_test.dart`. CI runs it on Flutter 3.47.5 on three OSes, and on Flutter 3.44 in the `min-sdk` job. The `build` job runs the compiled `appstein sync` and fails if any part came from the notes. See [ci](ci.md).

## When a new Flutter stable is released

1. Download its four files into a new `test/fixtures/flutter_sdk/<version>/` folder (Task 5 of the 1b.2 plan has the commands), and add the version to `fixtureFlutterVersions`.
2. If a parser test fails, Flutter changed a shape. Teach the parser the new shape, and keep the old one working.
3. Add `notes/<minor>.yaml` with that version's matrix (see [How to: add a curated note](how-to/add-a-curated-note.md)). The fallback test then checks it against the new fixtures.
4. Bump `newestKnownFlutterMinor` in `supported_versions.dart` to the new minor. A test compares it with the newest notes file, and fails until you do.
