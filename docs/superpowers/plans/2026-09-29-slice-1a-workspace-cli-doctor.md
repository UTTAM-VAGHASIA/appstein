# Slice 1a: Workspace, CLI, SDK Detection and Doctor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Appstein Dart workspace, with four packages, an `appstein` CLI that has `--version` and `doctor`, `appstein.yaml` loading, FVM-aware Flutter SDK detection, the `layer_imports` boundary lint running on our own repo, an AOT build, CI on Windows, macOS and Linux, and the developer-guide skeleton.

**Architecture:** A Dart pub workspace with four packages, following spec §5.1:
- `appstein_protocol` holds pure data models.
- `appstein_engine` holds all logic: host access, config, SDK detection and doctor.
- `appstein_cli` is a thin `package:args` layer over the engine.
- `appstein_lints` is an analyzer plugin, built on `analysis_server_plugin`.

The engine never touches the process environment directly. Everything goes through `HostEnvironment` and `ProcessRunner`, so tests can fake it. Tests use real temporary folders whose paths contain spaces and non-ASCII characters, because Windows is first-class.

**Tech Stack:**
- Dart 3.13.4, via Flutter 3.47.5 pinned with FVM. Packages declare `sdk: ^3.12.0`.
- Libraries: `args`, `path`, `yaml`, `pub_semver`, `glob`.
- Analyzer plugin: `analysis_server_plugin` 0.3.23, with `analyzer` 14.4.0.
- Testing: `test`, `analyzer_testing` 0.4.2, `test_reflective_loader`.
- CI: GitHub Actions with `subosito/flutter-action@v2`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. The sections this slice implements are §4, §5.1–5.3, §7, §9.5, §9.6 (the `layer_imports` rule only), §15, §18 (1a), §19 and §22 (items 14 and 21).

## Global Constraints

- **SDK:** every package's pubspec declares `environment: sdk: ^3.12.0`. Flutter 3.44 ships Dart 3.12, and 3.44 is the proposed minimum Flutter version (spec §22 #14).
- **Tooling:** run every Dart command through FVM: `fvm dart …`, `fvm flutter …`. The repo pins Flutter **3.47.5** in `.fvmrc`. The `dart` on your PATH may be an older SDK; never use it.
- **Windows is first-class:** paths with spaces, drive letters and non-ASCII characters must work. The product ships no bash scripts. CI YAML may use bash.
- **Exit codes (spec §9.5):**
  - `0`: no errors.
  - `1`: errors found.
  - `3`: Appstein itself failed, including bad usage and crashes.
  - `2` (hook mode) arrives in slice 1d, so don't add it now.
- **Never touch agent credentials:** `doctor` only runs `--version` on agent CLIs.
- **No network calls** in this slice. No telemetry, ever.
- **Package boundaries (spec §5.1):**
  - `protocol` depends on nothing internal.
  - `engine` depends only on `protocol`.
  - `cli` depends on `engine` and `protocol`.
  - `lints` depends only on `protocol`.
- **Documentation:**
  - Every public API has a `///` doc comment; `public_member_api_docs` is on.
  - Doc comments say what a thing is for, not how it is implemented.
- **Output text:** plain ASCII status labels (`[ok]`, `[warn]`, `[error]`, `[info]`, `[skip]`), so output reads correctly in any Windows console code page.
- **Performance targets (spec §15):**
  - AOT start-up for `appstein --version` stays under **200 ms** (median).
  - Fast verify stays under **5 s**; this slice measures it and records the result (Task 13).
- **Git:**
  - Work on the branch `slice-1a`.
  - Every "Commit" step needs the owner's approval first (AGENTS.md). Never push.
  - Commit messages end with the `Co-Authored-By` trailer given in the session.

## Review Focus

These are inputs the spec implies but no feature test would naturally hit. Each has a pinned test in the task that owns the code.

1. **Paths with spaces and non-ASCII characters** (`C:\Users\Jöhn Doe\my app`) in the project root, the SDK path and PATH entries. Everything must still work. Pinned by the `tempDir()` helper (Task 3), which every file-system test uses, and by the `.bat`-with-spaces runner test (Task 3).
2. **Messy Windows PATH values:** empty entries (`;;`), quoted entries (`"C:\Program Files\x"`) and variable names in any case (`Path` vs `PATH`). Pinned in Task 3.
3. **Child tools that hang or print invalid UTF-8.** A broken JDK or an odd locale must not hang or crash `doctor`. Pinned in Task 3 (timeout test, malformed-bytes test).
4. **An `appstein.yaml` that isn't a map:** a list root, duplicate keys, an unquoted `baseline: 3.20` or tabs. Each gives a `ConfigException` with a line number, never a crash. Pinned in Task 4.
5. **A dangling FVM link.** `.fvm/flutter_sdk` can point at a deleted version after `fvm remove`. Detection falls back to FVM's cache, or says exactly which version to install. Pinned in Task 5.

## Evidence Gathered Before Planning (2026-09-29, on the development machine)

These facts come from throwaway spikes. Tasks rely on them, so they are recorded here.

- **FVM layout:**
  - FVM 3.2.1, with its cache at `C:\Users\<you>\fvm\versions\<version>`.
  - `bin/cache/flutter.version.json` for 3.47.5 contains `frameworkVersion: 3.47.5`, `channel: stable` and `dartSdkVersion: 3.13.4`.
  - `bin/cache/dart-sdk/version` contains `3.13.4`.
  - An SDK that FVM hasn't "set up" yet has neither file.
- **Analyzer plugins (Dart 3.13.4, `analysis_server_plugin` 0.3.23, analyzer 14.4.0):**
  - Custom keys inside a plugin's own `plugins:` entry trigger the warning `unsupported_option`. Only `path`, `version`, `git`, `hosted` and `diagnostics` are allowed.
  - A **top-level** `appstein_lints:` key gives no warning, and a rule can read it. The owner approved this location, and the spec was updated (§5.1, §9.6).
  - A plugin inside a pub workspace (`resolution: workspace`) loads by `path:` and lints every workspace member.
  - In a workspace, `RuleContext.package.root` is the *member* package, so a rule must walk up from the file to find `analysis_options.yaml`.
  - `Folder.getChildAssumingFile` is deprecated; use `Folder.getFile`.
  - Plugin lint rules are **off by default**, so they must be listed under `diagnostics:`.
  - `analysis_server_plugin` 0.3.23 pins `analyzer: 14.4.0`, which needs Dart `^3.11.0`. That is compatible with the 3.44 / Dart 3.12 minimum on paper; Task 15 CI proves it.
- **Cold `dart analyze` with the plugin:** about **2.1 s** on a one-file project (Windows, development machine). Task 13 measures a realistic app.
- **`dart doc`** has `--dry-run`, but `--validate-links` can't be combined with it.
- **Flutter's settings file:**
  - Windows: `%APPDATA%\.flutter_settings`.
  - macOS/Linux: `~/.flutter_settings` if it exists, else `$XDG_CONFIG_HOME/settings`, else `~/.config/flutter/settings`.
  - Source: `flutter_tools/lib/src/base/config.dart`.
- **Flutter's JDK order:** `jdk-dir` setting, then Android Studio's bundled JBR, then `JAVA_HOME`, then `java` on PATH. Source: `flutter_tools/lib/src/android/java.dart`.
  - **On the development machine, Android Studio's JBR is broken** (`could not open jvm.cfg`) while `JAVA_HOME` is JDK 21. That is a real case for the Java check (Task 7).
- **Flutter's Android SDK lookup:**
  - The first **defined** of the `android-sdk` setting, `ANDROID_HOME`, `ANDROID_SDK_ROOT` and the default folder wins. The default folder is `%USERPROFILE%\AppData\Local\Android\sdk` on Windows, `~/Library/Android/sdk` on macOS and `~/Android/Sdk` on Linux.
  - A folder is a valid SDK when it has `licenses/` or `platform-tools/`. After that come `aapt`/`adb` on PATH.
  - Source: `flutter_tools/lib/src/android/android_sdk.dart`.
- **Owner's tools:**
  - The Android SDK has `build-tools` 35.0.0, 36.1.0 and 37.0.0-rc2.
  - `codex` is installed by npm, which creates `codex.cmd`; PATHEXT lookup finds that.
- **`dependency_validator` 5.x** supports pub workspaces.

## Planning Decisions (explained for the owner)

- **Why a separate `DoctorReport` model instead of `Finding`?** Findings (spec §9.3) describe problems in *code*, with a file and line. Doctor results describe the *machine*: they have no file and they include `ok` results. Sharing one model would make both awkward. `Severity` is shared.
- **Why real temporary folders instead of an in-memory file system?** The riskiest bugs are real Windows path behaviour: spaces, `.bat` quoting, junctions. An in-memory file system would hide exactly those.
- **Why doesn't `doctor` run `flutter doctor` or `flutter config`?** Both take seconds. Reading Flutter's own settings file and version files gives the same facts in milliseconds. Each lookup cites the `flutter_tools` source it mirrors, so it can be re-checked when Flutter changes.
- **Why are guide Dart snippets rejected for now?** Spec §19.6 wants guide snippets analyzed. That tooling is shared with skills CI in slice 1f. Until then, the guide checker refuses `dart` code blocks, so nothing unchecked slips in.
- **`publish_to: none`** stays on every package until the license decision (spec §19.5).

## File Map

```
appstein/
├── .fvmrc                                  Flutter 3.47.5 pin (Task 1)
├── pubspec.yaml                            workspace root + dev tools (Task 1)
├── analysis_options.yaml                   lints, strict modes, plugin + boundaries (Tasks 1, 11)
├── dart_dependency_validator.yaml          (Task 15, only if needed)
├── tool/
│   ├── startup_check.dart                  AOT start-up budget (Task 12)
│   ├── measure_analyze.dart                fast-verify measurement (Task 13)
│   ├── check_guide.dart                    guide checker entry point (Task 14)
│   └── src/guide_checker.dart              guide checker logic (Task 14)
├── test/guide_checker_test.dart            (Task 14)
├── docs/guide/{README,architecture,debugging}.md   (Task 14)
├── .github/workflows/ci.yml                (Task 15)
└── packages/
    ├── appstein_protocol/
    │   ├── lib/appstein_protocol.dart      barrel
    │   └── lib/src/{protocol_version,severity,sdk_info,layer_rules}.dart, config/appstein_config.dart
    ├── appstein_engine/
    │   ├── lib/appstein_engine.dart        barrel
    │   ├── lib/src/host/{host_environment,process_runner,executable_finder,file_links}.dart
    │   ├── lib/src/text/edit_distance.dart
    │   ├── lib/src/config/config_loader.dart
    │   ├── lib/src/project/project_locator.dart
    │   ├── lib/src/sdk/{fvm_pin,flutter_sdk_locator,flutter_sdk_reader,language_version,sdk_detector,supported_versions}.dart
    │   ├── lib/src/android/{flutter_settings,java_locator,android_sdk_locator}.dart
    │   ├── lib/src/doctor/{doctor,doctor_check,check_helpers}.dart
    │   ├── lib/src/doctor/checks/{flutter_check,dart_check,fvm_check,project_check,java_check,android_sdk_check,xcode_check,cocoapods_check,tool_check,agents_check,appstein_path_check}.dart
    │   └── test/… (mirrors lib/src; support/ has helpers)
    ├── appstein_cli/
    │   ├── bin/appstein.dart
    │   ├── lib/appstein_cli.dart           barrel (runAppstein)
    │   └── lib/src/{runner,version,exit_codes,project_option,doctor_command,doctor_printer}.dart
    └── appstein_lints/
        ├── lib/main.dart                   plugin entry point
        └── lib/src/{appstein_lints_plugin.dart, layer_imports/{layer_config,layer_matcher,layer_imports_rule}.dart}
```

---

### Task 1: Workspace scaffold and FVM pin

**Files:**
- Create: `.fvmrc` (by `fvm use`), `pubspec.yaml`, `analysis_options.yaml`
- Create: `packages/appstein_protocol/{pubspec.yaml,README.md,lib/appstein_protocol.dart,lib/src/protocol_version.dart,test/protocol_version_test.dart}`
- Create: `packages/appstein_engine/{pubspec.yaml,README.md,lib/appstein_engine.dart}`
- Create: `packages/appstein_cli/{pubspec.yaml,README.md,lib/appstein_cli.dart}`
- Create: `packages/appstein_lints/{pubspec.yaml,README.md,lib/main.dart}` (a placeholder until Task 10)
- Modify: `.gitignore`

**Interfaces:**
- Produces: `const int protocolVersion` (in `package:appstein_protocol`), and the four package names that later tasks import.

- [ ] **Step 1: Create the branch and pin Flutter with FVM**

```powershell
git switch -c slice-1a
fvm use 3.47.5 --skip-pub-get
Get-Content .fvmrc
```
Expected: `.fvmrc` contains `"flutter": "3.47.5"`. FVM may also create `.fvm/` and edit `.gitignore` or `.vscode/`. Note whether it created a `.fvm/flutter_sdk` link, because Task 5 relies on that behaviour. Record the answer in the Task 5 notes.

- [ ] **Step 2: Write the workspace root `pubspec.yaml`**

```yaml
name: appstein_workspace
description: Development workspace for the Appstein toolkit. Not published.
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - packages/appstein_protocol
  - packages/appstein_engine
  - packages/appstein_cli
  - packages/appstein_lints
```

- [ ] **Step 3: Write each package's `pubspec.yaml`**

`packages/appstein_protocol/pubspec.yaml`:
```yaml
name: appstein_protocol
description: Shared data models for Appstein, a knowledge and verification layer for AI agents that build Flutter apps.
version: 0.1.0-dev
repository: https://github.com/UTTAM-VAGHASIA/appstein
publish_to: none

environment:
  sdk: ^3.12.0

resolution: workspace
```

`packages/appstein_engine/pubspec.yaml`:
```yaml
name: appstein_engine
description: The Appstein engine. SDK detection, configuration, doctor, and later knowledge and verification.
version: 0.1.0-dev
repository: https://github.com/UTTAM-VAGHASIA/appstein
publish_to: none

environment:
  sdk: ^3.12.0

resolution: workspace

dependencies:
  appstein_protocol: ^0.1.0-dev
```

`packages/appstein_cli/pubspec.yaml`:
```yaml
name: appstein_cli
description: The appstein command-line tool.
version: 0.1.0-dev
repository: https://github.com/UTTAM-VAGHASIA/appstein
publish_to: none

environment:
  sdk: ^3.12.0

resolution: workspace

executables:
  appstein: appstein

dependencies:
  appstein_engine: ^0.1.0-dev
  appstein_protocol: ^0.1.0-dev
```

`packages/appstein_lints/pubspec.yaml`:
```yaml
name: appstein_lints
description: Appstein's analyzer plugin. Architecture and design lint rules for Flutter projects.
version: 0.1.0-dev
repository: https://github.com/UTTAM-VAGHASIA/appstein
publish_to: none

environment:
  sdk: ^3.12.0

resolution: workspace

dependencies:
  appstein_protocol: ^0.1.0-dev
```

- [ ] **Step 4: Add the external dependencies with `pub add`**

`pub add` picks the newest versions that work with our SDK and writes caret constraints.

```powershell
fvm dart pub add --dev lints test path --directory .
fvm dart pub add dev:test --directory packages/appstein_protocol
fvm dart pub add path yaml pub_semver --directory packages/appstein_engine
fvm dart pub add dev:test --directory packages/appstein_engine
fvm dart pub add args path --directory packages/appstein_cli
fvm dart pub add dev:test dev:yaml --directory packages/appstein_cli
fvm dart pub add analysis_server_plugin:^0.3.23 analyzer:^14.4.0 glob path yaml --directory packages/appstein_lints
fvm dart pub add dev:test dev:analyzer_testing dev:test_reflective_loader --directory packages/appstein_lints
fvm dart pub get
```
Expected: `Got dependencies!` and a single `pubspec.lock` at the repo root. The workspace shares one lock file. **Commit that lock file:** this repo ships an executable, so builds must be reproducible.

- [ ] **Step 5: Write the root `analysis_options.yaml`**

```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true

linter:
  rules:
    - public_member_api_docs
    - unawaited_futures
    - prefer_final_locals
```
There is only one options file, at the root. Member packages must **not** get their own, because the analyzer plugin (Task 11) is configured at the workspace root.

- [ ] **Step 6: Write the failing test**

`packages/appstein_protocol/test/protocol_version_test.dart`:
```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('the first protocol version is 1', () {
    expect(protocolVersion, 1);
  });
}
```

- [ ] **Step 7: Run it to verify it fails**

Run: `cd packages/appstein_protocol; fvm dart test`
Expected: FAIL. The library `package:appstein_protocol/appstein_protocol.dart` doesn't exist.

- [ ] **Step 8: Write the libraries**

`packages/appstein_protocol/lib/src/protocol_version.dart`:
```dart
/// The version of Appstein's data formats: the JSON it writes and the
/// models the CLI, MCP server and future UIs exchange.
///
/// It changes only when a format changes in a way older readers can't
/// handle, and `appstein upgrade` migrates stored data between versions.
const int protocolVersion = 1;
```

`packages/appstein_protocol/lib/appstein_protocol.dart`:
```dart
/// Shared data models for Appstein.
///
/// Every model the CLI, the engine and the lint rules exchange lives here, so
/// there is exactly one data format (spec §4, principle 4).
library;

export 'src/protocol_version.dart';
```

`packages/appstein_engine/lib/appstein_engine.dart`:
```dart
/// The Appstein engine: everything the CLI does, with no command-line code.
library;
```

`packages/appstein_cli/lib/appstein_cli.dart`:
```dart
/// The `appstein` command-line tool.
library;
```

`packages/appstein_lints/lib/main.dart` (this placeholder is replaced in Task 10):
```dart
/// Appstein's analyzer plugin. The rules arrive in Task 10 of slice 1a.
library;
```

- [ ] **Step 9: Write the four package READMEs**

`packages/appstein_protocol/README.md`:
```markdown
# appstein_protocol

Shared data models for Appstein: SDK facts, configuration, layer rules and severities.

- **May depend on:** no other Appstein package (spec §5.1).
- **Entry point:** `lib/appstein_protocol.dart`.
- **Test:** `cd packages/appstein_protocol; fvm dart test`.
```

`packages/appstein_engine/README.md`:
```markdown
# appstein_engine

Everything Appstein does, with no command-line code: host access, `appstein.yaml`, Flutter SDK detection and `doctor`. Later slices add knowledge, verification and the MCP server.

- **May depend on:** `appstein_protocol` only (spec §5.1).
- **Entry point:** `lib/appstein_engine.dart`.
- **Test:** `cd packages/appstein_engine; fvm dart test`. Tests tagged `integration` use the real machine: `fvm dart test --run-skipped --tags integration`.
```

`packages/appstein_cli/README.md`:
```markdown
# appstein_cli

The `appstein` command. It is a thin layer: it parses arguments, calls `appstein_engine` and prints the results.

- **May depend on:** `appstein_engine` and `appstein_protocol` (spec §5.1).
- **Entry points:** `bin/appstein.dart` and `runAppstein()` in `lib/appstein_cli.dart`.
- **Test:** `cd packages/appstein_cli; fvm dart test`.
```

`packages/appstein_lints/README.md`:
```markdown
# appstein_lints

Appstein's analyzer plugin. It runs inside the Dart analyzer, so its rules show up in every IDE and agent.

- **May depend on:** `appstein_protocol` only (spec §5.1). It never imports packs; stack packs write their layer rules into the project's `analysis_options.yaml`.
- **Entry point:** `lib/main.dart` (the `plugin` variable the analysis server loads).
- **Test:** `cd packages/appstein_lints; fvm dart test`.
```

- [ ] **Step 10: Ignore FVM's local folder**

Add these lines under `# Dart / Flutter` in `.gitignore`, unless `fvm use` already added them:
```
.fvm/
doc/api/
```

- [ ] **Step 11: Run the checks**

```powershell
fvm dart format .
fvm dart analyze --fatal-infos
cd packages/appstein_protocol; fvm dart test; cd ../..
```
Expected: no analyzer issues, and `All tests passed!`.

- [ ] **Step 12: Commit (after the owner approves)**

```powershell
git add .fvmrc .gitignore pubspec.yaml pubspec.lock analysis_options.yaml packages
git commit -m "chore: create the Dart workspace with four packages and pin Flutter 3.47.5"
```

---

### Task 2: Protocol models: `Severity`, `SdkInfo`, `LayerRules`

**Files:**
- Create: `packages/appstein_protocol/lib/src/severity.dart`, `lib/src/sdk_info.dart`, `lib/src/layer_rules.dart`
- Modify: `packages/appstein_protocol/lib/appstein_protocol.dart` (exports)
- Test: `packages/appstein_protocol/test/sdk_info_test.dart`, `test/layer_rules_test.dart`

**Interfaces:**
- Produces:
  - `enum Severity { error, warning, info }`.
  - `SdkInfo({required String flutterVersion, required String dartVersion, required String channel, String? languageVersion, String? fvmVersion})`, with `SdkInfo.fromJson(Map<String, Object?>)`, `Map<String, Object?> toJson()`, and value `==`. JSON keys: `flutter`, `dart`, `channel`, `languageVersion`, `fvm`.
  - `LayerRules({required Map<String, List<String>> layers, required Map<String, List<String>> allow})`, with `LayerRules.fromJson(Object?)` (throws `FormatException`), `bool mayImport(String fromTag, String toTag)` and `Map<String, Object?> toJson()`.

- [ ] **Step 1: Write the failing tests**

`packages/appstein_protocol/test/sdk_info_test.dart`:
```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const info = SdkInfo(
    flutterVersion: '3.47.5',
    dartVersion: '3.13.4',
    channel: 'stable',
    languageVersion: '3.9',
    fvmVersion: '3.47.5',
  );

  test('round-trips through JSON with the sdk.json key names', () {
    final json = info.toJson();
    expect(json, {
      'flutter': '3.47.5',
      'dart': '3.13.4',
      'channel': 'stable',
      'languageVersion': '3.9',
      'fvm': '3.47.5',
    });
    expect(SdkInfo.fromJson(json), info);
  });

  test('optional fields may be null', () {
    final json = {'flutter': '3.47.5', 'dart': '3.13.4', 'channel': 'stable'};
    final parsed = SdkInfo.fromJson(json);
    expect(parsed.languageVersion, isNull);
    expect(parsed.fvmVersion, isNull);
  });

  test('a missing required field is a FormatException', () {
    expect(
      () => SdkInfo.fromJson({'dart': '3.13.4', 'channel': 'stable'}),
      throwsA(isA<FormatException>()),
    );
  });
}
```

`packages/appstein_protocol/test/layer_rules_test.dart`:
```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final valid = {
    'layers': {
      'ui': ['lib/ui/**'],
      'domain': ['lib/domain/**'],
      'data.repository': ['lib/data/repositories/**'],
    },
    'allow': {
      'ui': ['domain'],
      'domain': <String>[],
    },
  };

  test('parses a valid section and keeps declaration order', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.layers.keys, ['ui', 'domain', 'data.repository']);
    expect(rules.allow['ui'], ['domain']);
  });

  test('a layer may import itself and its allowed layers', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.mayImport('ui', 'ui'), isTrue);
    expect(rules.mayImport('ui', 'domain'), isTrue);
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(rules.mayImport('domain', 'ui'), isFalse);
  });

  test('a layer without an allow entry is unrestricted', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.mayImport('data.repository', 'ui'), isTrue);
  });

  test('round-trips through JSON', () {
    final rules = LayerRules.fromJson(valid);
    expect(LayerRules.fromJson(rules.toJson()).toJson(), rules.toJson());
  });

  test('rejects an unknown key', () {
    expect(
      () => LayerRules.fromJson({'layer': {}}),
      throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('Unknown key "layer"'))),
    );
  });

  test('rejects an allow entry for an undeclared tag', () {
    expect(
      () => LayerRules.fromJson({
        'layers': {'ui': ['lib/ui/**']},
        'allow': {'ui': ['data']},
      }),
      throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('"data"'))),
    );
  });

  test('rejects a tag with capitals or spaces', () {
    expect(
      () => LayerRules.fromJson({
        'layers': {'Data Layer': ['lib/data/**']},
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a layer with no globs or a non-list value', () {
    expect(() => LayerRules.fromJson({'layers': {'ui': <String>[]}}),
        throwsA(isA<FormatException>()));
    expect(() => LayerRules.fromJson({'layers': {'ui': 'lib/ui/**'}}),
        throwsA(isA<FormatException>()));
  });

  test('a non-map section is a FormatException', () {
    expect(() => LayerRules.fromJson(['ui']), throwsA(isA<FormatException>()));
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/appstein_protocol; fvm dart test`
Expected: FAIL. `SdkInfo` and `LayerRules` are undefined.

- [ ] **Step 3: Write `severity.dart`**

```dart
/// How serious a finding is (spec §9.3).
enum Severity {
  /// Blocks "done".
  error,

  /// Reported, but never blocks.
  warning,

  /// Advisory only.
  info,
}
```

- [ ] **Step 4: Write `sdk_info.dart`**

```dart
/// Facts about the Flutter SDK a project uses.
///
/// This is the content of `.appstein/platform/sdk.json` (spec §6.2). Slice 1a
/// detects these facts; slice 1b writes them to disk and adds notes coverage.
final class SdkInfo {
  /// Creates SDK facts.
  const SdkInfo({
    required this.flutterVersion,
    required this.dartVersion,
    required this.channel,
    this.languageVersion,
    this.fvmVersion,
  });

  /// Reads SDK facts from their JSON form.
  ///
  /// Throws a [FormatException] when a required field is missing or has the
  /// wrong type.
  factory SdkInfo.fromJson(Map<String, Object?> json) {
    String readString(String key) {
      final value = json[key];
      if (value is String) return value;
      throw FormatException('sdk.json: "$key" must be a string.');
    }

    String? readOptional(String key) {
      final value = json[key];
      if (value == null || value is String) return value as String?;
      throw FormatException('sdk.json: "$key" must be a string or null.');
    }

    return SdkInfo(
      flutterVersion: readString('flutter'),
      dartVersion: readString('dart'),
      channel: readString('channel'),
      languageVersion: readOptional('languageVersion'),
      fvmVersion: readOptional('fvm'),
    );
  }

  /// The Flutter framework version, such as `3.47.5`.
  final String flutterVersion;

  /// The Dart SDK version bundled with Flutter, such as `3.13.4`.
  final String dartVersion;

  /// The Flutter channel, such as `stable`.
  final String channel;

  /// The project's Dart language version, such as `3.9`.
  ///
  /// It is the lower bound of the `sdk` constraint in `pubspec.yaml`. New
  /// syntax is gated by this, not by the installed SDK. Null when unknown.
  final String? languageVersion;

  /// The Flutter version the project pins with FVM, or null without FVM.
  final String? fvmVersion;

  /// The JSON form, with the key names used in `sdk.json`.
  Map<String, Object?> toJson() => {
        'flutter': flutterVersion,
        'dart': dartVersion,
        'channel': channel,
        'languageVersion': languageVersion,
        'fvm': fvmVersion,
      };

  @override
  bool operator ==(Object other) =>
      other is SdkInfo &&
      other.flutterVersion == flutterVersion &&
      other.dartVersion == dartVersion &&
      other.channel == channel &&
      other.languageVersion == languageVersion &&
      other.fvmVersion == fvmVersion;

  @override
  int get hashCode => Object.hash(
      flutterVersion, dartVersion, channel, languageVersion, fvmVersion);
}
```

- [ ] **Step 5: Write `layer_rules.dart`**

```dart
/// Which layer may import which, as declared by a stack pack (spec §9.6).
///
/// It is written into a project's `analysis_options.yaml` as a top-level
/// `appstein_lints:` section, and read by the `layer_imports` lint rule:
///
/// ```yaml
/// appstein_lints:
///   layers:          # tag: path globs, relative to analysis_options.yaml
///     ui: [lib/ui/**]
///     domain: [lib/domain/**]
///   allow:           # tag: the other tags it may import
///     ui: [domain]
///     domain: []
/// ```
///
/// A file gets the first tag, in declaration order, whose globs match it. A
/// layer may always import itself. A tag with no `allow` entry is
/// unrestricted.
final class LayerRules {
  /// Creates layer rules. Prefer [LayerRules.fromJson], which validates.
  const LayerRules({required this.layers, required this.allow});

  /// Parses and validates an `appstein_lints:` section.
  ///
  /// Throws a [FormatException] whose message is written for the person
  /// editing the file.
  factory LayerRules.fromJson(Object? json) {
    if (json is! Map<Object?, Object?>) {
      throw const FormatException(
          'appstein_lints must be a map with "layers" and "allow".');
    }
    for (final key in json.keys) {
      if (key != 'layers' && key != 'allow') {
        throw FormatException(
            'Unknown key "$key" in appstein_lints. Allowed: layers, allow.');
      }
    }
    final layers = _stringListMap(json['layers'], 'layers');
    for (final MapEntry(key: tag, value: globs) in layers.entries) {
      if (!_tagPattern.hasMatch(tag)) {
        throw FormatException('Layer tag "$tag" is not valid. Use lowercase '
            'words separated by dots, like "data.repository".');
      }
      if (globs.isEmpty) {
        throw FormatException('Layer "$tag" needs at least one path glob.');
      }
    }
    final allow = _stringListMap(json['allow'], 'allow');
    for (final MapEntry(key: tag, value: targets) in allow.entries) {
      if (!layers.containsKey(tag)) {
        throw FormatException('allow: "$tag" is not declared under layers.');
      }
      for (final target in targets) {
        if (!layers.containsKey(target)) {
          throw FormatException('allow: "$tag" lists "$target", which is '
              'not declared under layers.');
        }
      }
    }
    return LayerRules(layers: layers, allow: allow);
  }

  static final _tagPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

  static Map<String, List<String>> _stringListMap(Object? value, String name) {
    if (value == null) return const {};
    if (value is! Map<Object?, Object?>) {
      throw FormatException('appstein_lints.$name must be a map.');
    }
    final result = <String, List<String>>{};
    for (final MapEntry(:key, value: list) in value.entries) {
      if (key is! String) {
        throw FormatException(
            'appstein_lints.$name: every key must be a string.');
      }
      if (list is! List<Object?> ||
          list.any((item) => item is! String || item.isEmpty)) {
        throw FormatException(
            'appstein_lints.$name.$key must be a list of non-empty strings.');
      }
      result[key] = List.unmodifiable(list.cast<String>());
    }
    return Map.unmodifiable(result);
  }

  /// Layer tag → path globs, in match order.
  final Map<String, List<String>> layers;

  /// Layer tag → the other tags it may import.
  final Map<String, List<String>> allow;

  /// Whether code in [fromTag] may import code in [toTag].
  bool mayImport(String fromTag, String toTag) {
    if (fromTag == toTag) return true;
    final allowed = allow[fromTag];
    return allowed == null || allowed.contains(toTag);
  }

  /// The JSON form, which is also the YAML form.
  Map<String, Object?> toJson() => {'layers': layers, 'allow': allow};
}
```

- [ ] **Step 6: Export them**

In `lib/appstein_protocol.dart`, replace the export line with:
```dart
export 'src/layer_rules.dart';
export 'src/protocol_version.dart';
export 'src/sdk_info.dart';
export 'src/severity.dart';
```

- [ ] **Step 7: Run the tests and analyzer**

Run: `cd packages/appstein_protocol; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add packages/appstein_protocol
git commit -m "feat(protocol): add Severity, SdkInfo and LayerRules models"
```

---

### Task 3: Host layer (environment, process runner, executable finder)

**Why this exists:** every other engine component needs environment variables, the PATH and the ability to run tools. Putting all three behind small types means tests can fake them, and the Windows quirks live in one place: case-insensitive variables, quoted PATH entries, PATHEXT and `.bat` files needing a shell.

**Files:**
- Create: `packages/appstein_engine/lib/src/host/host_environment.dart`
- Create: `packages/appstein_engine/lib/src/host/process_runner.dart`
- Create: `packages/appstein_engine/lib/src/host/executable_finder.dart`
- Create: `packages/appstein_engine/lib/src/host/file_links.dart`
- Create: `packages/appstein_engine/test/support/temp.dart`, `test/support/fake_process_runner.dart`
- Test: `packages/appstein_engine/test/host/host_environment_test.dart`, `test/host/process_runner_test.dart`, `test/host/executable_finder_test.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (exports)

**Interfaces:**
- Produces:
  - `enum HostOs { windows, macos, linux }`, with `static HostOs get current`.
  - `HostEnvironment({required HostOs os, required Map<String, String> variables, required String workingDirectory})`, with `factory HostEnvironment.current()`, `String? variable(String name)` (case-insensitive on Windows; empty values count as unset), `String? get homeDir` and `List<String> get pathEntries`.
  - `RunResult`, with fields `exitCode`, `stdout`, `stderr`, `started` and `timedOut`, the getter `bool get ok`, and constructors `RunResult({required int exitCode, String stdout = '', String stderr = ''})`, `RunResult.notStarted(String reason)` and `RunResult.timedOut({required String stdout, required String stderr})`.
  - `abstract interface class ProcessRunner { Future<RunResult> run(String executable, List<String> arguments, {Duration timeout, Map<String, String>? environment}); }`, and `SystemProcessRunner` (const), whose default timeout is 20 s.
  - `String? findExecutable(String name, HostEnvironment environment)`.
  - `String resolveLinks(String path)`, which returns `path` unchanged when it can't be resolved.
  - Test support:
    - `Directory tempDir()`;
    - `String fakeExecutable(Directory dir, String name, {String output})`;
    - `HostEnvironment fakeEnvironment(Map<String, String> variables, {HostOs? os, String? workingDirectory})`;
    - `FakeProcessRunner`, with `void when(String executable, List<String> arguments, RunResult result)` and `List<String> calls`.

- [ ] **Step 1: Write the test support files**

`packages/appstein_engine/test/support/temp.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temporary folder whose path contains a space and a non-ASCII
/// character, and deletes it after the test.
///
/// Paths like `C:\Users\Jöhn Doe\my app` must work everywhere (spec §4,
/// principle 10), so every file-system test uses this.
Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('appstein tëst ');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Creates a fake executable named [name] in [dir] that prints [output], and
/// returns its path. On Windows it is `name.bat`.
String fakeExecutable(Directory dir, String name, {String output = 'fake'}) {
  if (Platform.isWindows) {
    final file = File(p.join(dir.path, '$name.bat'))
      ..writeAsStringSync('@echo off\r\necho $output\r\n');
    return file.path;
  }
  final file = File(p.join(dir.path, name))
    ..writeAsStringSync('#!/bin/sh\necho "$output"\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A [HostEnvironment] with only [variables], for the real OS unless [os] is
/// given. Pass a fake [os] only to tests that touch no files.
HostEnvironment fakeEnvironment(
  Map<String, String> variables, {
  HostOs? os,
  String? workingDirectory,
}) =>
    HostEnvironment(
      os: os ?? HostOs.current,
      // Keep tests away from the real machine's Program Files folder, where a
      // real Android Studio install would leak into the Java checks (Task 7).
      variables: {
        'ProgramFiles': r'Z:\appstein-test-no-program-files',
        ...variables,
      },
      workingDirectory: workingDirectory ?? Directory.systemTemp.path,
    );

/// The PATHEXT value Windows uses by default, for fake environments.
const defaultPathExt = '.COM;.EXE;.BAT;.CMD';
```

`packages/appstein_engine/test/support/fake_process_runner.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';

/// A [ProcessRunner] that returns canned results and records every call.
///
/// A command that wasn't set up with [when] "fails to start", just as a
/// missing tool would.
final class FakeProcessRunner implements ProcessRunner {
  final Map<String, RunResult> _results = {};

  /// Every command run, as `executable arg1 arg2`.
  final List<String> calls = [];

  /// Makes [executable] with [arguments] return [result].
  void when(String executable, List<String> arguments, RunResult result) {
    _results[_key(executable, arguments)] = result;
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  }) async {
    final key = _key(executable, arguments);
    calls.add(key);
    return _results[key] ?? RunResult.notStarted('not faked: $key');
  }

  static String _key(String executable, List<String> arguments) =>
      [executable, ...arguments].join(' ');
}
```

- [ ] **Step 2: Write the failing tests**

`packages/appstein_engine/test/host/host_environment_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('on Windows, variable names are case-insensitive', () {
    final env = fakeEnvironment({'Path': r'C:\bin'}, os: HostOs.windows);
    expect(env.variable('PATH'), r'C:\bin');
  });

  test('elsewhere, variable names are case-sensitive', () {
    final env = fakeEnvironment({'Path': '/bin'}, os: HostOs.linux);
    expect(env.variable('PATH'), isNull);
  });

  test('an empty variable counts as unset', () {
    final env = fakeEnvironment({'JAVA_HOME': ''}, os: HostOs.linux);
    expect(env.variable('JAVA_HOME'), isNull);
  });

  test('Windows PATH entries lose quotes and empty parts', () {
    final env = fakeEnvironment(
      {'PATH': r'C:\a;;"C:\Program Files\b";  ;'},
      os: HostOs.windows,
    );
    expect(env.pathEntries, [r'C:\a', r'C:\Program Files\b']);
  });

  test('POSIX PATH entries split on colons', () {
    final env = fakeEnvironment({'PATH': '/usr/bin::/opt/x'}, os: HostOs.linux);
    expect(env.pathEntries, ['/usr/bin', '/opt/x']);
  });

  test('home comes from USERPROFILE on Windows and HOME elsewhere', () {
    expect(
      fakeEnvironment({'USERPROFILE': r'C:\Users\a'}, os: HostOs.windows)
          .homeDir,
      r'C:\Users\a',
    );
    expect(fakeEnvironment({'HOME': '/home/a'}, os: HostOs.linux).homeDir,
        '/home/a');
  });
}
```

`packages/appstein_engine/test/host/executable_finder_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('finds an executable in a PATH folder with spaces', () {
    final dir = tempDir();
    final exe = fakeExecutable(dir, 'mytool');
    final env =
        fakeEnvironment({'PATH': dir.path, 'PATHEXT': defaultPathExt});
    expect(findExecutable('mytool', env), exe);
  });

  test('skips empty and quoted PATH entries', () {
    final dir = tempDir();
    final exe = fakeExecutable(dir, 'mytool');
    final value =
        Platform.isWindows ? ';;"${dir.path}";' : '::${dir.path}:';
    final env = fakeEnvironment({'PATH': value, 'PATHEXT': defaultPathExt});
    expect(findExecutable('mytool', env), exe);
  });

  test('returns null when the tool is missing', () {
    final env =
        fakeEnvironment({'PATH': tempDir().path, 'PATHEXT': defaultPathExt});
    expect(findExecutable('mytool', env), isNull);
  });

  test('on Windows, follows PATHEXT order', () {
    final dir = tempDir();
    File(p.join(dir.path, 'mytool.cmd')).writeAsStringSync('@echo off');
    final bat = File(p.join(dir.path, 'mytool.bat'))
      ..writeAsStringSync('@echo off');
    final env = fakeEnvironment({'PATH': dir.path, 'PATHEXT': '.BAT;.CMD'});
    expect(findExecutable('mytool', env), bat.path);
  }, testOn: 'windows');

  test('on POSIX, ignores files without the executable bit', () {
    final dir = tempDir();
    File(p.join(dir.path, 'mytool')).writeAsStringSync('#!/bin/sh');
    expect(findExecutable('mytool', fakeEnvironment({'PATH': dir.path})),
        isNull);
  }, testOn: '!windows');
}
```

`packages/appstein_engine/test/host/process_runner_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  const runner = SystemProcessRunner();

  test('runs a program and captures its output', () async {
    final result = await runner.run(Platform.resolvedExecutable, ['--version']);
    expect(result.ok, isTrue);
    expect(result.stdout + result.stderr, contains('Dart SDK version'));
  });

  test('runs a script whose path and argument contain spaces', () async {
    final dir = tempDir();
    final String script;
    if (Platform.isWindows) {
      script = (File(p.join(dir.path, 'echo arg.bat'))
            ..writeAsStringSync('@echo off\r\necho %~1\r\n'))
          .path;
    } else {
      script = (File(p.join(dir.path, 'echo arg'))
            ..writeAsStringSync('#!/bin/sh\necho "\$1"\n'))
          .path;
      Process.runSync('chmod', ['+x', script]);
    }
    final result = await runner.run(script, ['hello world']);
    expect(result.stdout.trim(), 'hello world');
  });

  test('reports a program that cannot start instead of throwing', () async {
    final result = await runner.run('appstein-no-such-tool-xyz', []);
    expect(result.started, isFalse);
    expect(result.ok, isFalse);
  });

  test('kills a program that runs past the timeout', () async {
    final script = File(p.join(tempDir().path, 'sleep.dart'))
      ..writeAsStringSync("import 'dart:io';\n"
          'void main() => sleep(const Duration(seconds: 30));\n');
    final watch = Stopwatch()..start();
    final result = await runner.run(Platform.resolvedExecutable, [script.path],
        timeout: const Duration(seconds: 3));
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('decodes output that is not valid UTF-8 without throwing', () async {
    final script = File(p.join(tempDir().path, 'bytes.dart'))
      ..writeAsStringSync("import 'dart:io';\n"
          'void main() { stdout.add([0xff, 0xfe, 0x41, 0x0a]); }\n');
    final result = await runner.run(Platform.resolvedExecutable, [script.path]);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('A'));
  });
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/host`
Expected: FAIL. `HostEnvironment`, `findExecutable` and `SystemProcessRunner` are undefined.

- [ ] **Step 4: Write `host_environment.dart`**

```dart
import 'dart:io';

/// The operating system Appstein runs on.
enum HostOs {
  /// Microsoft Windows.
  windows,

  /// Apple macOS.
  macos,

  /// Linux.
  linux;

  /// The OS of the running process.
  static HostOs get current => Platform.isWindows
      ? windows
      : Platform.isMacOS
          ? macos
          : linux;
}

/// The parts of the machine Appstein reads: the OS, environment variables and
/// the working folder.
///
/// The engine reads these only through this class, so tests can describe any
/// machine without changing the real one.
final class HostEnvironment {
  /// Describes a machine.
  const HostEnvironment({
    required this.os,
    required this.variables,
    required this.workingDirectory,
  });

  /// The machine this process runs on.
  factory HostEnvironment.current() => HostEnvironment(
        os: HostOs.current,
        variables: Platform.environment,
        workingDirectory: Directory.current.path,
      );

  /// The operating system.
  final HostOs os;

  /// Environment variables.
  final Map<String, String> variables;

  /// The folder commands run from.
  final String workingDirectory;

  /// The value of the environment variable [name], or null when it is unset
  /// or empty.
  ///
  /// On Windows, names are case-insensitive (`Path` and `PATH` are the same).
  String? variable(String name) {
    var value = variables[name];
    if (value == null && os == HostOs.windows) {
      final wanted = name.toLowerCase();
      for (final entry in variables.entries) {
        if (entry.key.toLowerCase() == wanted) {
          value = entry.value;
          break;
        }
      }
    }
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The user's home folder: `USERPROFILE` on Windows, `HOME` elsewhere.
  String? get homeDir => variable(os == HostOs.windows ? 'USERPROFILE' : 'HOME');

  /// The folders on PATH, in order, without empty entries or the quotes
  /// Windows allows around an entry.
  List<String> get pathEntries {
    final separator = os == HostOs.windows ? ';' : ':';
    final entries = <String>[];
    for (final raw in (variable('PATH') ?? '').split(separator)) {
      var entry = raw.trim();
      if (entry.length >= 2 && entry.startsWith('"') && entry.endsWith('"')) {
        entry = entry.substring(1, entry.length - 1);
      }
      if (entry.isNotEmpty) entries.add(entry);
    }
    return entries;
  }
}
```

- [ ] **Step 5: Write `process_runner.dart`**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The outcome of running a tool.
final class RunResult {
  /// A tool that ran to completion with [exitCode].
  const RunResult({required this.exitCode, this.stdout = '', this.stderr = ''})
      : started = true,
        timedOut = false;

  /// A tool that could not be started, for example because it isn't
  /// installed. [reason] says why.
  const RunResult.notStarted(String reason)
      : exitCode = -1,
        stdout = '',
        stderr = reason,
        started = false,
        timedOut = false;

  /// A tool that was killed because it ran past its time limit.
  const RunResult.timedOut({required this.stdout, required this.stderr})
      : exitCode = -1,
        started = true,
        timedOut = true;

  /// The exit code, or -1 when the tool didn't start or timed out.
  final int exitCode;

  /// Everything the tool printed to standard output.
  final String stdout;

  /// Everything the tool printed to standard error, or why it failed.
  final String stderr;

  /// Whether the tool started at all.
  final bool started;

  /// Whether the tool was killed for running too long.
  final bool timedOut;

  /// Whether the tool ran and exited with code 0.
  bool get ok => started && !timedOut && exitCode == 0;
}

/// Runs external tools, such as `java -version` or `git --version`.
abstract interface class ProcessRunner {
  /// Runs [executable] with [arguments] and waits for it, killing it after
  /// [timeout]. Never throws for a missing or failing tool; see [RunResult].
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  });
}

/// Runs tools as real processes.
final class SystemProcessRunner implements ProcessRunner {
  /// Creates a runner.
  const SystemProcessRunner();

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  }) async {
    // Windows can only run .bat and .cmd files through cmd.exe.
    final extension = p.extension(executable).toLowerCase();
    final runInShell =
        Platform.isWindows && (extension == '.bat' || extension == '.cmd');
    final Process process;
    try {
      process = await Process.start(executable, arguments,
          runInShell: runInShell, environment: environment);
    } on ProcessException catch (error) {
      return RunResult.notStarted(error.message);
    }
    // Tools can print bytes that aren't valid UTF-8 (for example a JDK in
    // another locale). Replace them instead of crashing.
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutText = process.stdout.transform(decoder).join();
    final stderrText = process.stderr.transform(decoder).join();
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      process.kill();
      return -1;
    });
    // A killed shell can leave a child holding the pipes open, so don't wait
    // for the output forever.
    const drain = Duration(seconds: 2);
    final out = await stdoutText.timeout(drain, onTimeout: () => '');
    final err = await stderrText.timeout(drain, onTimeout: () => '');
    if (timedOut) {
      return RunResult.timedOut(
        stdout: out,
        stderr: 'Timed out after ${timeout.inSeconds} s: '
            '$executable ${arguments.join(' ')}\n$err',
      );
    }
    return RunResult(exitCode: exitCode, stdout: out, stderr: err);
  }
}
```

- [ ] **Step 6: Write `executable_finder.dart` and `file_links.dart`**

`executable_finder.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'host_environment.dart';

/// Finds the command [name] on the PATH of [environment], the way a shell
/// would, and returns its full path, or null when it isn't installed.
///
/// On Windows it tries each PATHEXT extension in order (`.COM;.EXE;.BAT;.CMD`
/// by default). Elsewhere, the file must have an executable bit.
String? findExecutable(String name, HostEnvironment environment) {
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
      return candidate;
    }
  }
  return null;
}
```

`file_links.dart`:
```dart
import 'dart:io';

/// Follows symbolic links and Windows junctions in [path] to the real
/// location. Returns [path] unchanged when it can't be resolved.
String resolveLinks(String path) {
  try {
    return FileSystemEntity.isDirectorySync(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}
```

- [ ] **Step 7: Export them**

Replace the body of `packages/appstein_engine/lib/appstein_engine.dart` with:
```dart
/// The Appstein engine: everything the CLI does, with no command-line code.
library;

export 'src/host/executable_finder.dart';
export 'src/host/file_links.dart';
export 'src/host/host_environment.dart';
export 'src/host/process_runner.dart';
```

- [ ] **Step 8: Run the tests**

Run: `cd packages/appstein_engine; fvm dart test test/host`
Expected: `All tests passed!`, including the space-in-path `.bat` test on Windows.
- If that test fails, you've found a real Windows quoting bug. Fix it in `SystemProcessRunner`; don't loosen the test.
- If `Process.start` can't quote a `.bat` path containing `ë` or spaces, fall back to `cmd.exe /d /s /c "<quoted path> <quoted args>"` on Windows, and keep the test.

- [ ] **Step 9: Commit (after the owner approves)**

```powershell
git add packages/appstein_engine
git commit -m "feat(engine): add the host layer: environment, process runner and executable finder"
```

---

### Task 4: `appstein.yaml`: config model and validating loader

**Why this design:** the model lives in `protocol`, because it is shared data (spec §4, principle 4). Parsing and validation live in `engine`. Errors carry line and column, because "Unknown key" without a position is useless in a long file. Suppressions (§9.7) join the schema in slice 1d, together with the checks they suppress.

**Files:**
- Create: `packages/appstein_protocol/lib/src/config/appstein_config.dart`
- Create: `packages/appstein_engine/lib/src/text/edit_distance.dart`
- Create: `packages/appstein_engine/lib/src/config/config_loader.dart`
- Modify: both barrels (exports)
- Test: `packages/appstein_protocol/test/appstein_config_test.dart`, `packages/appstein_engine/test/text/edit_distance_test.dart`, `packages/appstein_engine/test/config/config_loader_test.dart`

**Interfaces:**
- Consumes: `Severity` (Task 2); `tempDir()` (Task 3).
- Produces:
  - `AppsteinConfig` (const, all defaults), with fields `formatVersion`, `packs`, `delta`, `verify`, `docs`, `packages` and `integrations`, and `toJson()`.
  - Each field has its own class: `PacksConfig{stack, platforms}`, `DeltaConfig{baseline}`, `VerifyConfig{fastTimeoutSeconds, buildOnFull, Map<String, Severity> severity}`, `DocsConfig{enabled, path}`, `PackagesConfig{staleAfterMonths, allow, deny}` and `IntegrationsConfig{agents, graphifyExport, developerKnowledgeMcp}`.
  - `int editDistance(String a, String b)` and `String? closestMatch(String input, Iterable<String> candidates, {int maxDistance = 2})`.
  - `const configFileName = 'appstein.yaml'`, `AppsteinConfig? loadConfig(String projectRoot)` and `AppsteinConfig parseConfig(String content, {String? sourcePath})`.
  - `ConfigException{message, sourcePath, line, column}` (1-based).

- [ ] **Step 1: Write the failing protocol test**

`packages/appstein_protocol/test/appstein_config_test.dart`:
```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('defaults match spec §7', () {
    expect(const AppsteinConfig().toJson(), {
      'appstein': 1,
      'packs': {'stack': 'official_mvvm', 'platforms': ['android', 'ios']},
      'delta': {'baseline': '3.16'},
      'verify': {
        'fast_timeout_seconds': 20,
        'build_on_full': true,
        'severity': <String, String>{},
      },
      'docs': {'enabled': true, 'path': 'docs/app'},
      'packages': {
        'stale_after_months': 12,
        'allow': <String>[],
        'deny': <String>[],
      },
      'integrations': {
        'agents': ['claude', 'codex'],
        'graphify_export': false,
        'developer_knowledge_mcp': false,
      },
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/appstein_protocol; fvm dart test test/appstein_config_test.dart`
Expected: FAIL. `AppsteinConfig` is undefined.

- [ ] **Step 3: Write `appstein_config.dart`**

```dart
import '../severity.dart';

/// Project configuration from `appstein.yaml` (spec §7).
///
/// Every field has a default, so an empty file is valid. The JSON form uses
/// the same key names as the YAML file.
final class AppsteinConfig {
  /// Creates a configuration. Omitted sections use their defaults.
  const AppsteinConfig({
    this.formatVersion = 1,
    this.packs = const PacksConfig(),
    this.delta = const DeltaConfig(),
    this.verify = const VerifyConfig(),
    this.docs = const DocsConfig(),
    this.packages = const PackagesConfig(),
    this.integrations = const IntegrationsConfig(),
  });

  /// The config format version (the `appstein:` key).
  final int formatVersion;

  /// Which stack and platform packs the project uses.
  final PacksConfig packs;

  /// How far back the version delta reaches.
  final DeltaConfig delta;

  /// Verifier settings.
  final VerifyConfig verify;

  /// Human documentation settings (spec §6.9).
  final DocsConfig docs;

  /// Package gate settings.
  final PackagesConfig packages;

  /// Agent and optional integrations.
  final IntegrationsConfig integrations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'appstein': formatVersion,
        'packs': packs.toJson(),
        'delta': delta.toJson(),
        'verify': verify.toJson(),
        'docs': docs.toJson(),
        'packages': packages.toJson(),
        'integrations': integrations.toJson(),
      };
}

/// The `packs:` section.
final class PacksConfig {
  /// Creates the section.
  const PacksConfig({
    this.stack = 'official_mvvm',
    this.platforms = const ['android', 'ios'],
  });

  /// The stack pack, such as `official_mvvm`.
  final String stack;

  /// The platform packs, such as `android` and `ios`.
  final List<String> platforms;

  /// The JSON form.
  Map<String, Object?> toJson() => {'stack': stack, 'platforms': platforms};
}

/// The `delta:` section.
final class DeltaConfig {
  /// Creates the section.
  const DeltaConfig({this.baseline = '3.16'});

  /// Show API changes since this Flutter version, such as `3.16`.
  final String baseline;

  /// The JSON form.
  Map<String, Object?> toJson() => {'baseline': baseline};
}

/// The `verify:` section.
final class VerifyConfig {
  /// Creates the section.
  const VerifyConfig({
    this.fastTimeoutSeconds = 20,
    this.buildOnFull = true,
    this.severity = const {},
  });

  /// Safety cap for a fast verify run. The target is under 5 s (spec §15).
  final int fastTimeoutSeconds;

  /// Whether `verify --full` runs real debug builds.
  final bool buildOnFull;

  /// Per-check severity overrides, keyed by check ID.
  final Map<String, Severity> severity;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'fast_timeout_seconds': fastTimeoutSeconds,
        'build_on_full': buildOnFull,
        'severity': {for (final e in severity.entries) e.key: e.value.name},
      };
}

/// The `docs:` section.
final class DocsConfig {
  /// Creates the section.
  const DocsConfig({this.enabled = true, this.path = 'docs/app'});

  /// Whether human docs are rendered.
  final bool enabled;

  /// Where they go, relative to the project root, with `/` separators.
  final String path;

  /// The JSON form.
  Map<String, Object?> toJson() => {'enabled': enabled, 'path': path};
}

/// The `packages:` section.
final class PackagesConfig {
  /// Creates the section.
  const PackagesConfig({
    this.staleAfterMonths = 12,
    this.allow = const [],
    this.deny = const [],
  });

  /// A package with no release for this many months gets a warning.
  final int staleAfterMonths;

  /// Packages exempt from the maintenance warning.
  final List<String> allow;

  /// Packages that are always blocked.
  final List<String> deny;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'stale_after_months': staleAfterMonths,
        'allow': allow,
        'deny': deny,
      };
}

/// The `integrations:` section.
final class IntegrationsConfig {
  /// Creates the section.
  const IntegrationsConfig({
    this.agents = const ['claude', 'codex'],
    this.graphifyExport = false,
    this.developerKnowledgeMcp = false,
  });

  /// The agents `integrate` sets up.
  final List<String> agents;

  /// Whether `sync` also writes a graphify export (spec §16).
  final bool graphifyExport;

  /// Whether the Google Developer Knowledge MCP is enabled (spec §16).
  final bool developerKnowledgeMcp;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'agents': agents,
        'graphify_export': graphifyExport,
        'developer_knowledge_mcp': developerKnowledgeMcp,
      };
}
```

Add `export 'src/config/appstein_config.dart';` to `lib/appstein_protocol.dart`, keeping the exports sorted.

- [ ] **Step 4: Run the protocol test**

Run: `cd packages/appstein_protocol; fvm dart test`
Expected: `All tests passed!`

- [ ] **Step 5: Write the failing engine tests**

`packages/appstein_engine/test/text/edit_distance_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('edit distance counts single-character edits', () {
    expect(editDistance('kitten', 'sitting'), 3);
    expect(editDistance('', 'abc'), 3);
    expect(editDistance('same', 'same'), 0);
  });

  test('closest match suggests a likely typo and nothing for noise', () {
    const keys = ['packs', 'packages', 'delta'];
    expect(closestMatch('pakages', keys), 'packages');
    expect(closestMatch('zzzzzz', keys), isNull);
  });
}
```

`packages/appstein_engine/test/config/config_loader_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

Matcher configError(String text, {int? line}) => isA<ConfigException>()
    .having((e) => e.message, 'message', contains(text))
    .having((e) => e.line, 'line', line ?? anything);

void main() {
  test('an empty file gives the defaults', () {
    expect(parseConfig('').toJson(), const AppsteinConfig().toJson());
    expect(parseConfig('# only a comment\n').toJson(),
        const AppsteinConfig().toJson());
  });

  test('parses the spec §7 example', () {
    final config = parseConfig('''
appstein: 1
packs:
  stack: official_mvvm
  platforms: [android, ios]
delta:
  baseline: "3.16"
verify:
  fast_timeout_seconds: 20
  build_on_full: true
  severity:
    ui.no_hardcoded_colors: warning
docs:
  enabled: true
  path: docs/app
packages:
  stale_after_months: 12
  allow: []
  deny: [some_bad_pkg]
integrations:
  agents: [claude, codex]
  graphify_export: false
  developer_knowledge_mcp: false
''');
    expect(config.verify.severity, {'ui.no_hardcoded_colors': Severity.warning});
    expect(config.packages.deny, ['some_bad_pkg']);
  });

  test('an unknown key names the line and suggests the fix', () {
    expect(
      () => parseConfig('appstein: 1\npakages:\n  deny: []\n'),
      throwsA(configError('Did you mean "packages"?', line: 2)),
    );
  });

  test('an unquoted baseline explains the YAML number trap', () {
    expect(() => parseConfig('delta:\n  baseline: 3.20\n'),
        throwsA(configError('must be quoted', line: 2)));
  });

  test('an unsupported format version is rejected', () {
    expect(() => parseConfig('appstein: 2\n'),
        throwsA(configError('format 2 is not supported')));
  });

  test('values outside the allowed set are rejected', () {
    expect(() => parseConfig('packs:\n  platforms: [android, web]\n'),
        throwsA(configError('"web" is not allowed')));
    expect(() => parseConfig('verify:\n  severity:\n    ui.x: loud\n'),
        throwsA(configError('must be error, warning or info')));
    expect(() => parseConfig('verify:\n  fast_timeout_seconds: 0\n'),
        throwsA(configError('at least 1')));
  });

  test('docs.path must stay inside the project', () {
    expect(() => parseConfig('docs:\n  path: /tmp/docs\n'),
        throwsA(configError('not absolute')));
    expect(() => parseConfig('docs:\n  path: C:\\docs\n'),
        throwsA(configError('not absolute')));
    expect(() => parseConfig('docs:\n  path: ../outside\n'),
        throwsA(configError('inside the project')));
    expect(parseConfig('docs:\n  path: docs\\app\n').docs.path, 'docs/app');
  });

  // Review Focus 4: malformed files must give a positioned error, never a crash.
  test('a list, a duplicate key or broken YAML gives a positioned error', () {
    expect(() => parseConfig('- a\n- b\n'), throwsA(configError('must be a map')));
    expect(() => parseConfig('docs:\n  enabled: true\n  enabled: false\n'),
        throwsA(isA<ConfigException>().having((e) => e.line, 'line', isNotNull)));
    expect(() => parseConfig('packs: [unclosed\n'),
        throwsA(isA<ConfigException>().having((e) => e.line, 'line', isNotNull)));
  });

  test('loadConfig returns null without a file and reads one in a spaced path',
      () {
    final dir = tempDir();
    expect(loadConfig(dir.path), isNull);
    File(p.join(dir.path, configFileName))
        .writeAsStringSync('docs:\n  enabled: false\n');
    expect(loadConfig(dir.path)!.docs.enabled, isFalse);
  });

  test('the error message includes the file path', () {
    final dir = tempDir();
    File(p.join(dir.path, configFileName)).writeAsStringSync('nope: 1\n');
    expect(
      () => loadConfig(dir.path),
      throwsA(isA<ConfigException>()
          .having((e) => e.toString(), 'toString', contains(configFileName))),
    );
  });
}
```

- [ ] **Step 6: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/text test/config`
Expected: FAIL. `editDistance` and `parseConfig` are undefined.

- [ ] **Step 7: Write `edit_distance.dart`**

```dart
import 'dart:math' show min;

/// The Levenshtein distance between [a] and [b]: the fewest single-character
/// insertions, deletions or substitutions that turn one into the other.
int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = min(min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + cost);
    }
    previous = current;
  }
  return previous[b.length];
}

/// The candidate closest to [input], if it is at most [maxDistance] edits
/// away. Ties go to the earlier candidate. Used for "did you mean" hints.
String? closestMatch(String input, Iterable<String> candidates,
    {int maxDistance = 2}) {
  String? best;
  var bestDistance = maxDistance + 1;
  for (final candidate in candidates) {
    final distance = editDistance(input, candidate);
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}
```

- [ ] **Step 8: Write `config_loader.dart`**

```dart
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../text/edit_distance.dart';

/// The name of Appstein's project configuration file.
const configFileName = 'appstein.yaml';

/// The `appstein:` format version this build reads.
const supportedConfigFormat = 1;

/// Stack packs this build knows. The list grows as packs are added.
const knownStacks = ['official_mvvm'];

/// Target platforms supported in M1.
const knownPlatforms = ['android', 'ios'];

/// Agents that `integrate` can set up in M1.
const knownAgents = ['claude', 'codex'];

/// Thrown when `appstein.yaml` is invalid.
///
/// Carries the position, so the message points at the exact line.
final class ConfigException implements Exception {
  /// Creates a config error at an optional position.
  ConfigException(this.message, {this.sourcePath, this.line, this.column});

  /// What is wrong, written for the person editing the file.
  final String message;

  /// The file the error is in, when known.
  final String? sourcePath;

  /// The 1-based line, when known.
  final int? line;

  /// The 1-based column, when known.
  final int? column;

  @override
  String toString() {
    final position = StringBuffer();
    if (sourcePath != null) position.write(sourcePath);
    if (line != null) {
      if (position.isNotEmpty) position.write(':');
      position.write(line);
      if (column != null) position.write(':$column');
    }
    return position.isEmpty ? message : '$position: $message';
  }
}

/// Loads `appstein.yaml` from [projectRoot].
///
/// Returns null when the file doesn't exist, meaning the project isn't set
/// up with Appstein yet. Throws [ConfigException] when the file is invalid.
AppsteinConfig? loadConfig(String projectRoot) {
  final file = File(p.join(projectRoot, configFileName));
  if (!file.existsSync()) return null;
  return parseConfig(file.readAsStringSync(), sourcePath: file.path);
}

/// Parses and validates the text of an `appstein.yaml` file.
///
/// Every key has a default, so an empty file is valid. Unknown keys are
/// errors, with a "did you mean" hint for likely typos.
AppsteinConfig parseConfig(String content, {String? sourcePath}) {
  final YamlNode root;
  try {
    root = loadYamlNode(content,
        sourceUrl: sourcePath == null ? null : p.toUri(sourcePath));
  } on YamlException catch (error) {
    final span = error.span;
    throw ConfigException(
      error.message,
      sourcePath: sourcePath,
      line: span == null ? null : span.start.line + 1,
      column: span == null ? null : span.start.column + 1,
    );
  }
  if (root is YamlScalar && root.value == null) return const AppsteinConfig();
  return _ConfigReader(sourcePath).read(root);
}

final class _ConfigReader {
  _ConfigReader(this.sourcePath);

  final String? sourcePath;

  static final _checkIdPattern =
      RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');
  static final _packageNamePattern = RegExp(r'^[a-z_][a-z0-9_]*$');
  static final _flutterMinorPattern = RegExp(r'^\d+\.\d+$');

  AppsteinConfig read(YamlNode root) {
    final top = _map(root, 'appstein.yaml');
    _checkKeys(top, 'appstein.yaml', const [
      'appstein', 'packs', 'delta', 'verify', 'docs', 'packages',
      'integrations',
    ]);
    final format = _int(top, 'appstein', 'appstein',
        fallback: supportedConfigFormat);
    if (format != supportedConfigFormat) {
      throw _error(top.nodes['appstein']!,
          'Config format $format is not supported; this Appstein reads '
          'format $supportedConfigFormat.');
    }
    return AppsteinConfig(
      packs: _packs(_section(top, 'packs')),
      delta: _delta(_section(top, 'delta')),
      verify: _verify(_section(top, 'verify')),
      docs: _docs(_section(top, 'docs')),
      packages: _packages(_section(top, 'packages')),
      integrations: _integrations(_section(top, 'integrations')),
    );
  }

  PacksConfig _packs(YamlMap? map) {
    const defaults = PacksConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'packs', const ['stack', 'platforms']);
    return PacksConfig(
      stack: _string(map, 'stack', 'packs.stack',
          fallback: defaults.stack, oneOf: knownStacks),
      platforms: _stringList(map, 'platforms', 'packs.platforms',
          fallback: defaults.platforms, oneOf: knownPlatforms, nonEmpty: true),
    );
  }

  DeltaConfig _delta(YamlMap? map) {
    if (map == null) return const DeltaConfig();
    _checkKeys(map, 'delta', const ['baseline']);
    final node = map.nodes['baseline'];
    if (node == null || _isNull(node)) return const DeltaConfig();
    final value = node.value;
    if (value is num) {
      throw _error(node, 'delta.baseline must be quoted, like "3.16". '
          'Unquoted, YAML reads 3.20 as the number 3.2.');
    }
    if (value is! String || !_flutterMinorPattern.hasMatch(value)) {
      throw _error(node, 'delta.baseline must be a Flutter version like "3.16".');
    }
    return DeltaConfig(baseline: value);
  }

  VerifyConfig _verify(YamlMap? map) {
    const defaults = VerifyConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'verify',
        const ['fast_timeout_seconds', 'build_on_full', 'severity']);
    final severity = <String, Severity>{};
    final severityMap = _section(map, 'severity', where: 'verify.severity');
    if (severityMap != null) {
      for (final entry in severityMap.nodes.entries) {
        final keyNode = entry.key as YamlNode;
        final id = keyNode.value;
        if (id is! String || !_checkIdPattern.hasMatch(id)) {
          throw _error(keyNode, 'verify.severity: "$id" is not a check ID. '
              'Check IDs look like "ui.no_hardcoded_colors".');
        }
        final level = entry.value.value;
        final matches = Severity.values.where((s) => s.name == level);
        if (matches.isEmpty) {
          throw _error(entry.value,
              'verify.severity.$id must be error, warning or info.');
        }
        severity[id] = matches.single;
      }
    }
    return VerifyConfig(
      fastTimeoutSeconds: _int(map, 'fast_timeout_seconds',
          'verify.fast_timeout_seconds',
          fallback: defaults.fastTimeoutSeconds),
      buildOnFull: _bool(map, 'build_on_full', 'verify.build_on_full',
          fallback: defaults.buildOnFull),
      severity: Map.unmodifiable(severity),
    );
  }

  DocsConfig _docs(YamlMap? map) {
    const defaults = DocsConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'docs', const ['enabled', 'path']);
    var docsPath = defaults.path;
    final node = map.nodes['path'];
    if (node != null && !_isNull(node)) {
      final raw = node.value;
      if (raw is! String || raw.trim().isEmpty) {
        throw _error(node, 'docs.path must be a folder path, like docs/app.');
      }
      if (p.posix.isAbsolute(raw) || p.windows.isAbsolute(raw)) {
        throw _error(node,
            'docs.path must be relative to the project root, not absolute.');
      }
      final normalized = p.posix.normalize(raw.replaceAll(r'\', '/'));
      if (normalized == '.' ||
          normalized == '..' ||
          normalized.startsWith('../')) {
        throw _error(node, 'docs.path must be a folder inside the project.');
      }
      docsPath = normalized;
    }
    return DocsConfig(
      enabled: _bool(map, 'enabled', 'docs.enabled', fallback: defaults.enabled),
      path: docsPath,
    );
  }

  PackagesConfig _packages(YamlMap? map) {
    const defaults = PackagesConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'packages', const ['stale_after_months', 'allow', 'deny']);
    return PackagesConfig(
      staleAfterMonths: _int(map, 'stale_after_months',
          'packages.stale_after_months',
          fallback: defaults.staleAfterMonths),
      allow: _stringList(map, 'allow', 'packages.allow',
          fallback: defaults.allow, pattern: _packageNamePattern),
      deny: _stringList(map, 'deny', 'packages.deny',
          fallback: defaults.deny, pattern: _packageNamePattern),
    );
  }

  IntegrationsConfig _integrations(YamlMap? map) {
    const defaults = IntegrationsConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'integrations',
        const ['agents', 'graphify_export', 'developer_knowledge_mcp']);
    return IntegrationsConfig(
      agents: _stringList(map, 'agents', 'integrations.agents',
          fallback: defaults.agents, oneOf: knownAgents),
      graphifyExport: _bool(map, 'graphify_export',
          'integrations.graphify_export',
          fallback: defaults.graphifyExport),
      developerKnowledgeMcp: _bool(map, 'developer_knowledge_mcp',
          'integrations.developer_knowledge_mcp',
          fallback: defaults.developerKnowledgeMcp),
    );
  }

  ConfigException _error(YamlNode node, String message) => ConfigException(
        message,
        sourcePath: sourcePath,
        line: node.span.start.line + 1,
        column: node.span.start.column + 1,
      );

  bool _isNull(YamlNode node) => node is YamlScalar && node.value == null;

  YamlMap _map(YamlNode node, String where) {
    if (node is YamlMap) return node;
    throw _error(node, '$where must be a map of keys and values.');
  }

  YamlMap? _section(YamlMap parent, String key, {String? where}) {
    final node = parent.nodes[key];
    if (node == null || _isNull(node)) return null;
    return _map(node, where ?? key);
  }

  void _checkKeys(YamlMap map, String where, List<String> allowed) {
    for (final keyNode in map.nodes.keys.cast<YamlNode>()) {
      final key = keyNode.value;
      if (key is String && allowed.contains(key)) continue;
      final suggestion = key is String ? closestMatch(key, allowed) : null;
      final hint = suggestion == null ? '' : ' Did you mean "$suggestion"?';
      throw _error(keyNode, 'Unknown key "$key" in $where.$hint '
          'Allowed keys: ${allowed.join(', ')}.');
    }
  }

  bool _bool(YamlMap map, String key, String where, {required bool fallback}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is bool) return value;
    throw _error(node, '$where must be true or false.');
  }

  int _int(YamlMap map, String key, String where, {required int fallback}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is int && value >= 1) return value;
    throw _error(node, '$where must be a whole number of at least 1.');
  }

  String _string(YamlMap map, String key, String where,
      {required String fallback, List<String>? oneOf}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is String && (oneOf == null || oneOf.contains(value))) {
      return value;
    }
    throw _error(node, oneOf == null
        ? '$where must be text.'
        : '$where must be one of: ${oneOf.join(', ')}.');
  }

  List<String> _stringList(YamlMap map, String key, String where,
      {required List<String> fallback,
      List<String>? oneOf,
      RegExp? pattern,
      bool nonEmpty = false}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    if (node is! YamlList) {
      throw _error(node, '$where must be a list, like [a, b].');
    }
    final result = <String>[];
    for (final item in node.nodes) {
      final value = item.value;
      if (value is! String) {
        throw _error(item, 'Every entry in $where must be text.');
      }
      if (oneOf != null && !oneOf.contains(value)) {
        throw _error(item, '"$value" is not allowed in $where. '
            'Allowed: ${oneOf.join(', ')}.');
      }
      if (pattern != null && !pattern.hasMatch(value)) {
        throw _error(item, '"$value" in $where is not a valid package name.');
      }
      if (result.contains(value)) {
        throw _error(item, '"$value" appears twice in $where.');
      }
      result.add(value);
    }
    if (nonEmpty && result.isEmpty) {
      throw _error(node, '$where needs at least one entry.');
    }
    return List.unmodifiable(result);
  }
}
```

Add these exports to `lib/appstein_engine.dart`:
```dart
export 'src/config/config_loader.dart';
export 'src/text/edit_distance.dart';
```

- [ ] **Step 9: Run the tests and the analyzer**

Run: `cd packages/appstein_engine; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.
- If the duplicate-key test shows that `package:yaml` accepts duplicate keys silently, that's a real gap. Add a duplicate check in `_checkKeys` (track seen keys, and throw `'"$key" appears twice in $where.'`), and keep the test.

- [ ] **Step 10: Commit (after the owner approves)**

```powershell
git add packages
git commit -m "feat: load and validate appstein.yaml with positioned errors"
```

---

### Task 5: Project root and FVM-aware Flutter SDK detection

**Why this design:** detection reads files instead of running `flutter --version`. Running Flutter takes seconds and can trigger downloads; the files answer the same question in milliseconds.
- The lookup order matches what a developer's own tools use. The project's FVM pin wins, then `FLUTTER_ROOT`, then `flutter` on PATH.
- Every failure comes back as a problem plus a concrete fix, never an exception, so `doctor` can print it.

**Files:**
- Create: `packages/appstein_engine/lib/src/project/project_locator.dart`
- Create: `packages/appstein_engine/lib/src/sdk/{fvm_pin,flutter_sdk_locator,flutter_sdk_reader,language_version,sdk_detector,supported_versions}.dart`
- Create: `packages/appstein_engine/test/support/fake_sdk.dart`
- Test: `packages/appstein_engine/test/project/project_locator_test.dart`, `test/sdk/{fvm_pin_test,flutter_sdk_locator_test,flutter_sdk_reader_test,language_version_test,sdk_detector_test}.dart`
- Modify: `lib/appstein_engine.dart` (exports)

**Interfaces:**
- Consumes: `HostEnvironment`, `HostOs`, `findExecutable`, `resolveLinks` (Task 3); `SdkInfo` (Task 2).
- Produces:
  - `String? findProjectRoot(String start)`.
  - `FvmPin{version, configPath}` and `FvmPin? readFvmPin(String projectRoot)`, which throws `FormatException`.
  - `enum SdkSource { fvm, flutterRoot, path }`, each with a `label`.
  - `SdkLocation{root, source, fvmVersion}`.
  - `SdkLookup`, with the constructors `.found(SdkLocation)` and `.failed(String problem, String fixHint)`.
  - `FlutterSdkLocator(HostEnvironment)`, with `SdkLookup locate({String? projectRoot})`.
  - `FlutterSdkVersions{flutter, dart, channel}`, with `FlutterSdkVersions readSdkVersions(String sdkRoot)`. That function throws `SdkNotSetUpException` (field `sdkRoot`) or `FormatException`.
  - `String? languageVersionFromPubspec(String pubspecContent)`.
  - `SdkDetection`, with the constructors `.found(SdkInfo info, SdkLocation location)` and `.failed(String problem, String fixHint, {SdkLocation? location})`, and the fields `info`, `location`, `problem` and `fixHint`.
  - `SdkDetector(HostEnvironment)`, with `SdkDetection detect({String? projectRoot})`.
  - `final minSupportedFlutter = Version(3, 44, 0)`, `const newestKnownFlutterMinor = '3.47'` and `const minimumXcodeMajor = 26`.
  - Test support: `String createFakeSdk(String root, {String flutter = '3.47.5', String dart = '3.13.4', String channel = 'stable', bool setUp = true})`.

- [ ] **Step 1: Note what `fvm use` created in Task 1**

If Task 1 showed that FVM 3.2.1 does **not** create `.fvm/flutter_sdk`, still keep the link lookup below. Older FVM 3 versions create it, and teammates may run them. The cache fallback covers the owner's version. Record the observation here: `.fvm/flutter_sdk` created by FVM 3.2.1: ____ (yes/no).

- [ ] **Step 2: Write the fake SDK helper**

`packages/appstein_engine/test/support/fake_sdk.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds the parts of a Flutter SDK folder that Appstein reads, at [root].
///
/// With [setUp] false, it leaves out the version files, like an SDK that
/// FVM downloaded but Flutter hasn't run yet ("Need setup").
/// The JSON matches Flutter 3.47.5's real `bin/cache/flutter.version.json`.
String createFakeSdk(
  String root, {
  String flutter = '3.47.5',
  String dart = '3.13.4',
  String channel = 'stable',
  bool setUp = true,
}) {
  Directory(p.join(root, 'packages', 'flutter')).createSync(recursive: true);
  final bin = Directory(p.join(root, 'bin'))..createSync(recursive: true);
  File(p.join(bin.path, Platform.isWindows ? 'flutter.bat' : 'flutter'))
      .writeAsStringSync('');
  if (setUp) {
    final cache = Directory(p.join(bin.path, 'cache', 'dart-sdk'))
      ..createSync(recursive: true);
    File(p.join(cache.path, 'version')).writeAsStringSync('$dart\n');
    File(p.join(bin.path, 'cache', 'flutter.version.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'frameworkVersion': flutter,
      'channel': channel,
      'repositoryUrl': 'https://github.com/flutter/flutter.git',
      'frameworkRevision': '6a19cca56475dbfba1478ee68d7bd0c2ef891da1',
      'dartSdkVersion': dart,
      'devToolsVersion': '2.60.0',
      'flutterVersion': flutter,
    }));
  }
  return root;
}
```

- [ ] **Step 3: Write the failing tests**

`packages/appstein_engine/test/project/project_locator_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('finds the nearest folder with pubspec.yaml above the start', () {
    final root = tempDir();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app');
    final nested = Directory(p.join(root.path, 'lib', 'ui'))
      ..createSync(recursive: true);
    expect(findProjectRoot(nested.path), root.path);
  });

  test('returns null when no folder above has a pubspec.yaml', () {
    expect(findProjectRoot(tempDir().path), isNull);
  });
}
```

`packages/appstein_engine/test/sdk/fvm_pin_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('reads .fvmrc (FVM 3)', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    expect(readFvmPin(dir.path)!.version, '3.47.5');
  });

  test('reads .fvm/fvm_config.json (FVM 2)', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvm', 'fvm_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"flutterSdkVersion": "3.44.0"}');
    expect(readFvmPin(dir.path)!.version, '3.44.0');
  });

  test('returns null without FVM and throws on a broken file', () {
    final dir = tempDir();
    expect(readFvmPin(dir.path), isNull);
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{not json');
    expect(() => readFvmPin(dir.path), throwsA(isA<FormatException>()));
  });
}
```

`packages/appstein_engine/test/sdk/flutter_sdk_locator_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  late Directory work;
  late String project;

  setUp(() {
    work = tempDir();
    project = Directory(p.join(work.path, 'my app')).path;
    Directory(project).createSync();
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: my_app');
  });

  void pin(String version) => File(p.join(project, '.fvmrc'))
      .writeAsStringSync('{"flutter": "$version"}');

  test('uses the FVM cache for the pinned version', () {
    pin('3.47.5');
    final cache = p.join(work.path, 'fvm cache');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final env = fakeEnvironment({'FVM_CACHE_PATH': cache});
    final lookup = FlutterSdkLocator(env).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.fvm);
    expect(lookup.location!.fvmVersion, '3.47.5');
  });

  test('prefers the project .fvm/flutter_sdk link when it is valid', () {
    pin('3.47.5');
    final real = createFakeSdk(p.join(work.path, 'real sdk'));
    Link(p.join(project, '.fvm', 'flutter_sdk')).createSync(real, recursive: true);
    final lookup =
        FlutterSdkLocator(fakeEnvironment({})).locate(projectRoot: project);
    expect(p.equals(lookup.location!.root, resolveLinks(real)), isTrue);
  });

  // Review Focus 5: after `fvm remove`, the link can dangle.
  test('a dangling link falls back to the FVM cache', () {
    pin('3.47.5');
    final gone = Directory(p.join(work.path, 'removed sdk'))..createSync();
    Link(p.join(project, '.fvm', 'flutter_sdk'))
        .createSync(gone.path, recursive: true);
    gone.deleteSync();
    final cache = p.join(work.path, 'fvm cache');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final lookup = FlutterSdkLocator(fakeEnvironment({'FVM_CACHE_PATH': cache}))
        .locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.fvm);
  });

  test('a pinned version that is not installed says how to install it', () {
    pin('3.46.0');
    final lookup = FlutterSdkLocator(
            fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}))
        .locate(projectRoot: project);
    expect(lookup.location, isNull);
    expect(lookup.fixHint, contains('fvm install 3.46.0'));
  });

  test('without FVM, uses FLUTTER_ROOT', () {
    final sdk = createFakeSdk(p.join(work.path, 'flutter root'));
    final lookup = FlutterSdkLocator(fakeEnvironment({'FLUTTER_ROOT': sdk}))
        .locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.flutterRoot);
  });

  test('without FVM or FLUTTER_ROOT, uses flutter on PATH', () {
    final sdk = createFakeSdk(p.join(work.path, 'päth sdk'));
    final env = fakeEnvironment(
        {'PATH': p.join(sdk, 'bin'), 'PATHEXT': defaultPathExt});
    final lookup = FlutterSdkLocator(env).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.path);
    expect(p.equals(lookup.location!.root, resolveLinks(sdk)), isTrue);
  });

  test('with nothing installed, explains what to do', () {
    final lookup =
        FlutterSdkLocator(fakeEnvironment({})).locate(projectRoot: project);
    expect(lookup.problem, contains('No Flutter SDK found'));
  });
}
```

`packages/appstein_engine/test/sdk/flutter_sdk_reader_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  test('reads Flutter, Dart and channel from flutter.version.json', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'));
    final versions = readSdkVersions(sdk);
    expect(versions.flutter, '3.47.5');
    expect(versions.dart, '3.13.4');
    expect(versions.channel, 'stable');
  });

  test('keeps only the version from a beta Dart string', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'),
        dart: '3.14.0 (build 3.14.0-150.0.dev)', channel: 'beta');
    expect(readSdkVersions(sdk).dart, '3.14.0');
  });

  test('an SDK that was never run is "not set up"', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'), setUp: false);
    expect(() => readSdkVersions(sdk), throwsA(isA<SdkNotSetUpException>()));
  });

  test('an unexpected file format is a FormatException', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'));
    File(p.join(sdk, 'bin', 'cache', 'flutter.version.json'))
        .writeAsStringSync('[]');
    expect(() => readSdkVersions(sdk), throwsA(isA<FormatException>()));
  });
}
```

`packages/appstein_engine/test/sdk/language_version_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('reads the lower bound of the SDK constraint', () {
    expect(languageVersionFromPubspec('environment:\n  sdk: ^3.9.0\n'), '3.9');
    expect(languageVersionFromPubspec("environment:\n  sdk: '>=3.7.2 <4.0.0'\n"),
        '3.7');
  });

  test('returns null when there is no lower bound or no constraint', () {
    expect(languageVersionFromPubspec('environment:\n  sdk: any\n'), isNull);
    expect(languageVersionFromPubspec('name: app\n'), isNull);
    expect(languageVersionFromPubspec('{broken'), isNull);
  });
}
```

`packages/appstein_engine/test/sdk/sdk_detector_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  test('combines location, versions and the project language version', () {
    final work = tempDir();
    final project = p.join(work.path, 'my app');
    Directory(project).createSync();
    File(p.join(project, 'pubspec.yaml'))
        .writeAsStringSync('name: a\nenvironment:\n  sdk: ^3.9.0\n');
    File(p.join(project, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    final cache = p.join(work.path, 'fvm');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final detection = SdkDetector(fakeEnvironment({'FVM_CACHE_PATH': cache}))
        .detect(projectRoot: project);
    expect(detection.info!.toJson(), {
      'flutter': '3.47.5',
      'dart': '3.13.4',
      'channel': 'stable',
      'languageVersion': '3.9',
      'fvm': '3.47.5',
    });
  });

  test('an SDK that was never run explains how to set it up', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'), setUp: false);
    final detection =
        SdkDetector(fakeEnvironment({'FLUTTER_ROOT': sdk})).detect();
    expect(detection.info, isNull);
    expect(detection.location, isNotNull);
    expect(detection.fixHint, contains('--version'));
  });
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/project test/sdk`
Expected: FAIL, because the functions are undefined.

- [ ] **Step 5: Write `project_locator.dart` and `supported_versions.dart`**

`lib/src/project/project_locator.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns the nearest folder at or above [start] that contains
/// `pubspec.yaml`, or null when there is none.
String? findProjectRoot(String start) {
  var dir = p.normalize(p.absolute(start));
  while (true) {
    if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}
```

`lib/src/sdk/supported_versions.dart`:
```dart
import 'package:pub_semver/pub_semver.dart';

/// The oldest Flutter release Appstein supports (spec §22, item 14).
///
/// Flutter 3.44 ships Dart 3.12, which the Dart MCP server requires, and it
/// made Swift Package Manager the default. CI checks this version in slice 1a.
final minSupportedFlutter = Version(3, 44, 0);

/// The newest Flutter minor version this Appstein was built and tested for.
///
/// On a newer SDK, everything generated from the SDK still works, but
/// curated notes may be missing (spec §6.4).
const newestKnownFlutterMinor = '3.47';

/// The oldest Xcode that can upload to the App Store (Xcode 26, required
/// since 2026-04-28). This moves into the curated notes in slice 1b.
const minimumXcodeMajor = 26;
```

- [ ] **Step 6: Write `fvm_pin.dart` and `flutter_sdk_locator.dart`**

`lib/src/sdk/fvm_pin.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A Flutter version a project pins with FVM, and the file that pins it.
final class FvmPin {
  /// Creates a pin.
  const FvmPin({required this.version, required this.configPath});

  /// The pinned version, such as `3.47.5` or `stable`.
  final String version;

  /// The file the pin came from.
  final String configPath;
}

/// Reads the FVM pin of [projectRoot]: `.fvmrc` (FVM 3) or
/// `.fvm/fvm_config.json` (FVM 2).
///
/// Returns null when the project doesn't use FVM. Throws a
/// [FormatException] when a pin file exists but can't be read.
FvmPin? readFvmPin(String projectRoot) {
  final fvmrc = File(p.join(projectRoot, '.fvmrc'));
  if (fvmrc.existsSync()) {
    return FvmPin(version: _read(fvmrc, 'flutter'), configPath: fvmrc.path);
  }
  final legacy = File(p.join(projectRoot, '.fvm', 'fvm_config.json'));
  if (legacy.existsSync()) {
    return FvmPin(
        version: _read(legacy, 'flutterSdkVersion'), configPath: legacy.path);
  }
  return null;
}

String _read(File file, String key) {
  final Object? data;
  try {
    data = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  if (data is Map<String, Object?>) {
    final version = data[key];
    if (version is String && version.isNotEmpty) return version;
  }
  throw FormatException('${file.path} has no "$key" version.');
}
```

`lib/src/sdk/flutter_sdk_locator.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';
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
  const SdkLocation({required this.root, required this.source, this.fvmVersion});

  /// The SDK folder (the one that contains `bin/flutter`).
  final String root;

  /// How it was found.
  final SdkSource source;

  /// The FVM-pinned version, when [source] is [SdkSource.fvm].
  final String? fvmVersion;
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
///    which is `FVM_CACHE_PATH` or `~/fvm`);
/// 2. the FLUTTER_ROOT environment variable;
/// 3. the `flutter` command on PATH.
final class FlutterSdkLocator {
  /// Creates a locator for [environment].
  const FlutterSdkLocator(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  /// Finds the SDK for [projectRoot], or for no project when it is null.
  SdkLookup locate({String? projectRoot}) {
    if (projectRoot != null) {
      final FvmPin? pin;
      try {
        pin = readFvmPin(projectRoot);
      } on FormatException catch (error) {
        return SdkLookup.failed('Could not read the FVM pin: ${error.message}',
            'Fix the file, or run `fvm use <version>` again.');
      }
      if (pin != null) return _locateFvm(projectRoot, pin);
    }
    final flutterRoot = environment.variable('FLUTTER_ROOT');
    if (flutterRoot != null && _isSdk(flutterRoot)) {
      return SdkLookup.found(
          SdkLocation(root: flutterRoot, source: SdkSource.flutterRoot));
    }
    final flutter = findExecutable('flutter', environment);
    if (flutter != null) {
      final root = p.dirname(p.dirname(resolveLinks(flutter)));
      if (_isSdk(root)) {
        return SdkLookup.found(SdkLocation(root: root, source: SdkSource.path));
      }
    }
    return const SdkLookup.failed(
      'No Flutter SDK found: the project has no FVM pin, FLUTTER_ROOT is not '
      'set, and `flutter` is not on PATH.',
      'Install Flutter (https://docs.flutter.dev/get-started/install), or pin '
          'a version in the project with `fvm use <version>`.',
    );
  }

  SdkLookup _locateFvm(String projectRoot, FvmPin pin) {
    final link = p.join(projectRoot, '.fvm', 'flutter_sdk');
    if (_isSdk(link)) {
      return SdkLookup.found(SdkLocation(
          root: resolveLinks(link),
          source: SdkSource.fvm,
          fvmVersion: pin.version));
    }
    final home = environment.homeDir;
    final cache = environment.variable('FVM_CACHE_PATH') ??
        (home == null ? null : p.join(home, 'fvm'));
    if (cache != null) {
      final root = p.join(cache, 'versions', pin.version);
      if (_isSdk(root)) {
        return SdkLookup.found(SdkLocation(
            root: root, source: SdkSource.fvm, fvmVersion: pin.version));
      }
    }
    return SdkLookup.failed(
      'The project pins Flutter ${pin.version} with FVM (${pin.configPath}), '
      'but that version is not installed.',
      'Run `fvm install ${pin.version}` in the project folder.',
    );
  }

  bool _isSdk(String root) {
    final flutter = environment.os == HostOs.windows ? 'flutter.bat' : 'flutter';
    return File(p.join(root, 'bin', flutter)).existsSync() &&
        Directory(p.join(root, 'packages', 'flutter')).existsSync();
  }
}
```

- [ ] **Step 7: Write `flutter_sdk_reader.dart` and `language_version.dart`**

`lib/src/sdk/flutter_sdk_reader.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when an SDK folder exists but Flutter hasn't run in it yet, so its
/// version files aren't there. FVM lists such versions as "Need setup".
final class SdkNotSetUpException implements Exception {
  /// Creates the exception for [sdkRoot].
  const SdkNotSetUpException(this.sdkRoot);

  /// The SDK folder.
  final String sdkRoot;

  @override
  String toString() => 'The Flutter SDK at $sdkRoot has not been set up yet.';
}

/// The versions an installed Flutter SDK reports.
final class FlutterSdkVersions {
  /// Creates the versions.
  const FlutterSdkVersions(
      {required this.flutter, required this.dart, required this.channel});

  /// The Flutter version, such as `3.47.5`.
  final String flutter;

  /// The bundled Dart version, such as `3.13.4`.
  final String dart;

  /// The channel, such as `stable`.
  final String channel;
}

/// Reads the versions from `bin/cache/flutter.version.json` in [sdkRoot].
///
/// This is the file `flutter --version --machine` prints, so reading it is
/// equivalent and takes milliseconds instead of seconds.
/// Throws [SdkNotSetUpException] when the file is missing, and a
/// [FormatException] when its contents are unexpected.
FlutterSdkVersions readSdkVersions(String sdkRoot) {
  final file = File(p.join(sdkRoot, 'bin', 'cache', 'flutter.version.json'));
  if (!file.existsSync()) throw SdkNotSetUpException(sdkRoot);
  final Object? data;
  try {
    data = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  if (data is! Map<String, Object?>) {
    throw FormatException('Unexpected contents in ${file.path}.');
  }
  final flutter = data['frameworkVersion'] ?? data['flutterVersion'];
  final dart = data['dartSdkVersion'];
  final channel = data['channel'] ?? 'unknown';
  if (flutter is! String || dart is! String || channel is! String) {
    throw FormatException('Unexpected contents in ${file.path}.');
  }
  // Beta and dev builds read like "3.14.0 (build 3.14.0-150.0.dev)".
  return FlutterSdkVersions(
      flutter: flutter, dart: dart.split(' ').first, channel: channel);
}
```

`lib/src/sdk/language_version.dart`:
```dart
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The project's Dart language version, such as `3.9`: the lower bound of the
/// `environment: sdk:` constraint in `pubspec.yaml`.
///
/// New syntax (for example dot shorthands) depends on this, not on the
/// installed SDK (spec §3). Returns null when there is no lower bound or the
/// file can't be read.
String? languageVersionFromPubspec(String pubspecContent) {
  final Object? doc;
  try {
    doc = loadYaml(pubspecContent);
  } on YamlException {
    return null;
  }
  if (doc is! Map<Object?, Object?>) return null;
  final environment = doc['environment'];
  if (environment is! Map<Object?, Object?>) return null;
  final sdk = environment['sdk'];
  if (sdk is! String) return null;
  final VersionConstraint constraint;
  try {
    constraint = VersionConstraint.parse(sdk);
  } on FormatException {
    return null;
  }
  final Version? min = switch (constraint) {
    Version version => version,
    VersionRange range => range.min,
    _ => null,
  };
  return min == null ? null : '${min.major}.${min.minor}';
}
```

- [ ] **Step 8: Write `sdk_detector.dart`**

```dart
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import 'flutter_sdk_locator.dart';
import 'flutter_sdk_reader.dart';
import 'language_version.dart';

/// What Appstein knows about a project's Flutter SDK: facts when detection
/// worked, or a problem with a fix when it didn't.
final class SdkDetection {
  /// Detection worked.
  const SdkDetection.found(SdkInfo this.info, SdkLocation this.location)
      : problem = null,
        fixHint = null;

  /// Detection failed. [location] is set when the SDK was found but unusable.
  const SdkDetection.failed(String this.problem, String this.fixHint,
      {this.location})
      : info = null;

  /// The SDK facts, when detection worked.
  final SdkInfo? info;

  /// Where the SDK is, when it was found.
  final SdkLocation? location;

  /// Why detection failed.
  final String? problem;

  /// What the user should do about it.
  final String? fixHint;
}

/// Detects the Flutter SDK a project uses and reads its versions.
final class SdkDetector {
  /// Creates a detector for [environment].
  const SdkDetector(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  /// Detects the SDK for [projectRoot], or without a project when it is null.
  SdkDetection detect({String? projectRoot}) {
    final lookup = FlutterSdkLocator(environment).locate(projectRoot: projectRoot);
    final location = lookup.location;
    if (location == null) {
      return SdkDetection.failed(lookup.problem!, lookup.fixHint!);
    }
    final FlutterSdkVersions versions;
    try {
      versions = readSdkVersions(location.root);
    } on SdkNotSetUpException catch (error) {
      return SdkDetection.failed(
        error.toString(),
        location.source == SdkSource.fvm
            ? 'Run `fvm flutter --version` once in the project so Flutter '
                'downloads its tools.'
            : 'Run `flutter --version` once so Flutter downloads its tools.',
        location: location,
      );
    } on FormatException catch (error) {
      return SdkDetection.failed(
        'Could not read the Flutter version: ${error.message}',
        'Reinstall this Flutter version.',
        location: location,
      );
    }
    String? languageVersion;
    if (projectRoot != null) {
      final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        languageVersion = languageVersionFromPubspec(pubspec.readAsStringSync());
      }
    }
    return SdkDetection.found(
      SdkInfo(
        flutterVersion: versions.flutter,
        dartVersion: versions.dart,
        channel: versions.channel,
        languageVersion: languageVersion,
        fvmVersion: location.fvmVersion,
      ),
      location,
    );
  }
}
```

Add these exports to `lib/appstein_engine.dart`:
```dart
export 'src/project/project_locator.dart';
export 'src/sdk/flutter_sdk_locator.dart';
export 'src/sdk/flutter_sdk_reader.dart';
export 'src/sdk/fvm_pin.dart';
export 'src/sdk/language_version.dart';
export 'src/sdk/sdk_detector.dart';
export 'src/sdk/supported_versions.dart';
```

- [ ] **Step 9: Run the tests and the analyzer**

Run: `cd packages/appstein_engine; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.
- On Windows, `Link.createSync` makes a junction for a folder, so no admin rights are needed.
- If a link test fails with a permission error, check that the target is an absolute folder path.

- [ ] **Step 10: Commit (after the owner approves)**

```powershell
git add packages/appstein_engine
git commit -m "feat(engine): detect the project's Flutter SDK, FVM-aware, with language version"
```

---

### Task 6: Doctor framework, plus the Flutter, Dart, FVM and project checks

**Why this design:**
- Each check is a small class with one job: `DoctorCheck.run` returns a `CheckResult`.
- The `Doctor` detects the SDK **once** and shares it through `DoctorContext`, so several checks don't repeat the same file reads.
- Checks run in parallel, because most of them wait on external tools. Results keep their declared order.
- A check that throws becomes an `error` result that names the bug. A single broken check never crashes `doctor`.

**Files:**
- Create: `packages/appstein_engine/lib/src/doctor/{doctor_check,doctor,check_helpers}.dart`
- Create: `packages/appstein_engine/lib/src/doctor/checks/{flutter_check,dart_check,fvm_check,project_check}.dart`
- Create: `packages/appstein_engine/test/support/doctor_support.dart`
- Test: `packages/appstein_engine/test/doctor/doctor_test.dart`, `test/doctor/checks/{flutter_check_test,dart_check_test,fvm_check_test,project_check_test}.dart`
- Modify: `lib/appstein_engine.dart` (exports)

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  - `enum CheckStatus { ok, info, warning, error, skipped }`.
  - `CheckResult{status, summary, details, fixHint}`, with the const constructors `.ok(summary, {details})`, `.info(summary, {details})`, `.warning(summary, {details, fixHint})`, `.error(summary, {details, fixHint})` and `.skipped(summary)`.
  - `DoctorContext{environment, runner, projectRoot, sdk}`.
  - `abstract interface class DoctorCheck { String get id; String get title; Future<CheckResult> run(DoctorContext context); }`.
  - `DoctorEntry{check, result}` and `DoctorReport{entries, hasErrors}`.
  - `Doctor({required HostEnvironment environment, required ProcessRunner runner, List<DoctorCheck>? checks})`, with `Future<DoctorReport> run({String? projectRoot})`.
  - `List<DoctorCheck> defaultDoctorChecks()` and `String firstLine(String text)`.
  - The check classes, each with a const constructor and these ids:
    - `FlutterCheck`: `doctor.flutter`
    - `DartCheck`: `doctor.dart`
    - `FvmCheck`: `doctor.fvm`
    - `ProjectCheck`: `doctor.project`
  - Test support: `DoctorContext testContext({SdkDetection? sdk, String? projectRoot, HostEnvironment? environment, ProcessRunner? runner})`.

- [ ] **Step 1: Write the doctor test support**

`packages/appstein_engine/test/support/doctor_support.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import 'fake_process_runner.dart';
import 'temp.dart';

/// A doctor context for one check. By default the SDK is Flutter 3.47.5
/// (stable), found through PATH, with an empty environment and a runner
/// that knows no commands.
DoctorContext testContext({
  SdkDetection? sdk,
  String? projectRoot,
  HostEnvironment? environment,
  ProcessRunner? runner,
}) =>
    DoctorContext(
      environment: environment ?? fakeEnvironment({}),
      runner: runner ?? FakeProcessRunner(),
      projectRoot: projectRoot,
      sdk: sdk ?? foundSdk(),
    );

/// A successful SDK detection with the given versions.
SdkDetection foundSdk({
  String flutter = '3.47.5',
  String channel = 'stable',
  String root = '/sdk',
  SdkSource source = SdkSource.path,
}) =>
    SdkDetection.found(
      SdkInfo(flutterVersion: flutter, dartVersion: '3.13.4', channel: channel),
      SdkLocation(root: root, source: source),
    );
```

- [ ] **Step 2: Write the failing tests**

`packages/appstein_engine/test/doctor/doctor_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/temp.dart';

final class _StaticCheck implements DoctorCheck {
  _StaticCheck(this.id, this.result);

  @override
  final String id;

  final CheckResult result;

  @override
  String get title => id;

  @override
  Future<CheckResult> run(DoctorContext context) async => result;
}

final class _ThrowingCheck implements DoctorCheck {
  @override
  String get id => 'boom';

  @override
  String get title => 'Boom';

  @override
  Future<CheckResult> run(DoctorContext context) async =>
      throw StateError('kaboom');
}

void main() {
  Doctor doctorWith(List<DoctorCheck> checks) => Doctor(
      environment: fakeEnvironment({}),
      runner: FakeProcessRunner(),
      checks: checks);

  test('runs every check and keeps their order', () async {
    final report = await doctorWith([
      _StaticCheck('a', const CheckResult.ok('fine')),
      _StaticCheck('b', const CheckResult.warning('hmm')),
    ]).run();
    expect(report.entries.map((e) => e.check.id), ['a', 'b']);
    expect(report.hasErrors, isFalse);
  });

  test('an error result makes the report have errors', () async {
    final report = await doctorWith(
        [_StaticCheck('a', const CheckResult.error('broken'))]).run();
    expect(report.hasErrors, isTrue);
  });

  test('a check that throws becomes an error, not a crash', () async {
    final report = await doctorWith([_ThrowingCheck()]).run();
    expect(report.entries.single.result.status, CheckStatus.error);
    expect(report.entries.single.result.summary, contains('kaboom'));
  });
}
```

`packages/appstein_engine/test/doctor/checks/flutter_check_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';

void main() {
  Future<CheckResult> check(SdkDetection sdk) =>
      const FlutterCheck().run(testContext(sdk: sdk));

  test('a supported stable SDK is ok', () async {
    final result = await check(foundSdk());
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'Flutter 3.47.5 (stable)');
  });

  test('an SDK older than the minimum is an error', () async {
    final result = await check(foundSdk(flutter: '3.41.2'));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('older than 3.44.0'));
  });

  test('an SDK newer than Appstein knows is info', () async {
    final result = await check(foundSdk(flutter: '3.48.1'));
    expect(result.status, CheckStatus.info);
    expect(result.details.join(' '), contains('may be incomplete'));
  });

  test('a non-stable channel is a warning', () async {
    final result = await check(foundSdk(channel: 'beta'));
    expect(result.status, CheckStatus.warning);
  });

  test('a failed detection passes its problem and fix through', () async {
    final result = await check(const SdkDetection.failed('No SDK', 'Install'));
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'No SDK');
    expect(result.fixHint, 'Install');
  });
}
```

`packages/appstein_engine/test/doctor/checks/dart_check_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  test('ok when dart on PATH belongs to the same SDK', () async {
    final sdk = tempDir();
    final bin = Directory(p.join(sdk.path, 'bin'))..createSync();
    fakeExecutable(bin, 'dart');
    final result = await const DartCheck().run(testContext(
      sdk: foundSdk(root: sdk.path),
      environment: fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
    ));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('Dart 3.13.4'));
  });

  test('info when dart on PATH is a different SDK', () async {
    final other = tempDir();
    fakeExecutable(other, 'dart');
    final result = await const DartCheck().run(testContext(
      sdk: foundSdk(root: tempDir().path, source: SdkSource.fvm),
      environment:
          fakeEnvironment({'PATH': other.path, 'PATHEXT': defaultPathExt}),
    ));
    expect(result.status, CheckStatus.info);
    expect(result.details.single, contains('fvm dart'));
  });

  test('skipped without a Flutter SDK', () async {
    final result = await const DartCheck()
        .run(testContext(sdk: const SdkDetection.failed('x', 'y')));
    expect(result.status, CheckStatus.skipped);
  });
}
```

`packages/appstein_engine/test/doctor/checks/fvm_check_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late Directory project;
  late Directory tools;

  setUp(() {
    project = tempDir();
    tools = tempDir();
  });

  Future<CheckResult> run({bool pin = false, bool fvmInstalled = false}) {
    if (pin) {
      File(p.join(project.path, '.fvmrc'))
          .writeAsStringSync('{"flutter": "3.47.5"}');
    }
    if (fvmInstalled) fakeExecutable(tools, 'fvm');
    return const FvmCheck().run(testContext(
      projectRoot: project.path,
      environment:
          fakeEnvironment({'PATH': tools.path, 'PATHEXT': defaultPathExt}),
    ));
  }

  test('ok when the project pins a version and fvm is installed', () async {
    final result = await run(pin: true, fvmInstalled: true);
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('3.47.5'));
  });

  test('warning when the project pins a version but fvm is missing', () async {
    expect((await run(pin: true)).status, CheckStatus.warning);
  });

  test('info when fvm is installed but the project has no pin', () async {
    expect((await run(fvmInstalled: true)).status, CheckStatus.info);
  });

  test('skipped when neither is present', () async {
    expect((await run()).status, CheckStatus.skipped);
  });

  test('error when the pin file is broken', () async {
    File(p.join(project.path, '.fvmrc')).writeAsStringSync('{oops');
    final result = await const FvmCheck()
        .run(testContext(projectRoot: project.path));
    expect(result.status, CheckStatus.error);
  });
}
```

`packages/appstein_engine/test/doctor/checks/project_check_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late Directory project;

  setUp(() {
    project = tempDir();
    File(p.join(project.path, 'pubspec.yaml'))
        .writeAsStringSync('name: a\nenvironment:\n  sdk: ^3.9.0\n');
  });

  Future<CheckResult> run() =>
      const ProjectCheck().run(testContext(projectRoot: project.path));

  test('skipped outside a project', () async {
    final result = await const ProjectCheck().run(testContext());
    expect(result.status, CheckStatus.skipped);
  });

  test('info without appstein.yaml, and shows the language version', () async {
    final result = await run();
    expect(result.status, CheckStatus.info);
    expect(result.details.join('\n'), contains('3.9'));
  });

  test('ok with a valid appstein.yaml', () async {
    File(p.join(project.path, 'appstein.yaml')).writeAsStringSync('appstein: 1\n');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.details.join('\n'), contains('official_mvvm'));
  });

  test('error with an invalid appstein.yaml, pointing at the line', () async {
    File(p.join(project.path, 'appstein.yaml'))
        .writeAsStringSync('appstein: 1\nbogus: true\n');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains(':2:'));
    expect(result.summary, contains('Unknown key "bogus"'));
  });
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/doctor`
Expected: FAIL, because the doctor types are undefined.

- [ ] **Step 4: Write `doctor_check.dart`**

```dart
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../sdk/sdk_detector.dart';

/// The outcome of one doctor check.
enum CheckStatus {
  /// Everything is fine.
  ok,

  /// Worth knowing, nothing to fix.
  info,

  /// Something may cause trouble later.
  warning,

  /// Something Appstein or Flutter needs is broken or missing.
  error,

  /// The check doesn't apply here.
  skipped,
}

/// What a doctor check found.
final class CheckResult {
  /// A result with any [status].
  const CheckResult(this.status, this.summary,
      {this.details = const [], this.fixHint});

  /// Everything is fine.
  const CheckResult.ok(this.summary, {this.details = const []})
      : status = CheckStatus.ok,
        fixHint = null;

  /// Worth knowing, nothing to fix.
  const CheckResult.info(this.summary, {this.details = const []})
      : status = CheckStatus.info,
        fixHint = null;

  /// Something may cause trouble later.
  const CheckResult.warning(this.summary,
      {this.details = const [], this.fixHint})
      : status = CheckStatus.warning;

  /// Something is broken or missing.
  const CheckResult.error(this.summary, {this.details = const [], this.fixHint})
      : status = CheckStatus.error;

  /// The check doesn't apply here.
  const CheckResult.skipped(this.summary)
      : status = CheckStatus.skipped,
        details = const [],
        fixHint = null;

  /// The outcome.
  final CheckStatus status;

  /// One line saying what was found.
  final String summary;

  /// Extra lines, such as paths, that help explain the summary.
  final List<String> details;

  /// What to do about a warning or error.
  final String? fixHint;
}

/// Everything a check may look at. It is built once per doctor run.
final class DoctorContext {
  /// Creates a context.
  const DoctorContext({
    required this.environment,
    required this.runner,
    required this.projectRoot,
    required this.sdk,
  });

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner runner;

  /// The project being checked, or null outside a project.
  final String? projectRoot;

  /// The Flutter SDK detection, shared by every check.
  final SdkDetection sdk;
}

/// One thing `appstein doctor` checks.
abstract interface class DoctorCheck {
  /// A stable ID, such as `doctor.flutter`.
  String get id;

  /// A short name shown to people, such as `Flutter SDK`.
  String get title;

  /// Runs the check.
  Future<CheckResult> run(DoctorContext context);
}
```

- [ ] **Step 5: Write `doctor.dart` and `check_helpers.dart`**

`lib/src/doctor/check_helpers.dart`:
```dart
/// The first non-empty line of [text], trimmed. Tools often print their
/// version on the first line.
String firstLine(String text) {
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}
```

`lib/src/doctor/doctor.dart`:
```dart
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../sdk/sdk_detector.dart';
import 'checks/dart_check.dart';
import 'checks/flutter_check.dart';
import 'checks/fvm_check.dart';
import 'checks/project_check.dart';
import 'doctor_check.dart';

/// One check and its result.
final class DoctorEntry {
  /// Pairs a check with its result.
  const DoctorEntry(this.check, this.result);

  /// The check that ran.
  final DoctorCheck check;

  /// What it found.
  final CheckResult result;
}

/// Everything one doctor run found, in check order.
final class DoctorReport {
  /// Creates a report.
  const DoctorReport(this.entries);

  /// One entry per check.
  final List<DoctorEntry> entries;

  /// Whether any check found an error.
  bool get hasErrors =>
      entries.any((entry) => entry.result.status == CheckStatus.error);
}

/// The checks `appstein doctor` runs, in the order they are shown.
List<DoctorCheck> defaultDoctorChecks() => const [
      FlutterCheck(),
      DartCheck(),
      FvmCheck(),
      ProjectCheck(),
    ];

/// Checks the environment and explains how to fix problems (spec §5.3).
final class Doctor {
  /// Creates a doctor that runs [checks] (by default, [defaultDoctorChecks]).
  Doctor({
    required this.environment,
    required this.runner,
    List<DoctorCheck>? checks,
  }) : checks = checks ?? defaultDoctorChecks();

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner runner;

  /// The checks to run.
  final List<DoctorCheck> checks;

  /// Runs every check for [projectRoot] (or outside a project when it is
  /// null). Checks run in parallel, and results keep the check order.
  Future<DoctorReport> run({String? projectRoot}) async {
    final context = DoctorContext(
      environment: environment,
      runner: runner,
      projectRoot: projectRoot,
      sdk: SdkDetector(environment).detect(projectRoot: projectRoot),
    );
    final results = await Future.wait(
        checks.map((check) => _runSafely(check, context)));
    return DoctorReport([
      for (var i = 0; i < checks.length; i++) DoctorEntry(checks[i], results[i]),
    ]);
  }

  Future<CheckResult> _runSafely(DoctorCheck check, DoctorContext context) async {
    try {
      return await check.run(context);
    } catch (error) {
      return CheckResult.error('The check itself failed: $error',
          fixHint: 'This is a bug in Appstein. Please report it.');
    }
  }
}
```

- [ ] **Step 6: Write the four checks**

`lib/src/doctor/checks/flutter_check.dart`:
```dart
import 'package:pub_semver/pub_semver.dart';

import '../../sdk/supported_versions.dart';
import '../doctor_check.dart';

/// Checks that the project's Flutter SDK is found and supported.
final class FlutterCheck implements DoctorCheck {
  /// Creates the check.
  const FlutterCheck();

  @override
  String get id => 'doctor.flutter';

  @override
  String get title => 'Flutter SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final sdk = context.sdk;
    final info = sdk.info;
    final location = sdk.location;
    if (info == null || location == null) {
      return CheckResult.error(sdk.problem!, fixHint: sdk.fixHint);
    }
    final details = ['Found through ${location.source.label}: ${location.root}'];
    final label = 'Flutter ${info.flutterVersion} (${info.channel})';
    final Version version;
    try {
      version = Version.parse(info.flutterVersion);
    } on FormatException {
      return CheckResult.warning('$label: this version number is unreadable.',
          details: details, fixHint: 'Use a stable Flutter release.');
    }
    if (version < minSupportedFlutter) {
      return CheckResult.error(
        'Flutter ${info.flutterVersion} is older than $minSupportedFlutter, '
        'the oldest version Appstein supports.',
        details: details,
        fixHint: 'Upgrade Flutter. With FVM: `fvm install <version>` then '
            '`fvm use <version>`.',
      );
    }
    final newest = Version.parse('$newestKnownFlutterMinor.0');
    if (version.major > newest.major ||
        (version.major == newest.major && version.minor > newest.minor)) {
      return CheckResult.info(label, details: [
        ...details,
        'Newer than $newestKnownFlutterMinor, the newest version this '
            'Appstein was built for. Version notes may be incomplete.',
      ]);
    }
    if (info.channel != 'stable') {
      return CheckResult.warning(label,
          details: details,
          fixHint: 'Appstein targets the stable channel. Pin a stable version '
              'with FVM or run `flutter channel stable`.');
    }
    return CheckResult.ok(label, details: details);
  }
}
```

`lib/src/doctor/checks/dart_check.dart`:
```dart
import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../host/file_links.dart';
import '../../sdk/flutter_sdk_locator.dart';
import '../doctor_check.dart';

/// Reports the Dart SDK bundled with Flutter, and warns when the `dart` on
/// PATH belongs to a different SDK.
final class DartCheck implements DoctorCheck {
  /// Creates the check.
  const DartCheck();

  @override
  String get id => 'doctor.dart';

  @override
  String get title => 'Dart SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final info = context.sdk.info;
    final location = context.sdk.location;
    if (info == null || location == null) {
      return const CheckResult.skipped('Needs a Flutter SDK (see above).');
    }
    final summary = 'Dart ${info.dartVersion} (bundled with Flutter)';
    final pathDart = findExecutable('dart', context.environment);
    if (pathDart != null) {
      final root = resolveLinks(location.root);
      final dart = resolveLinks(pathDart);
      if (!p.isWithin(root, dart)) {
        final yourCommand = location.source == SdkSource.fvm
            ? '`fvm dart`'
            : 'the `dart` inside ${location.root}';
        return CheckResult.info(summary, details: [
          '`dart` on PATH is $pathDart, from a different SDK. Appstein always '
              'uses the project\'s SDK; when you run Dart yourself, use '
              '$yourCommand.',
        ]);
      }
    }
    return CheckResult.ok(summary);
  }
}
```

`lib/src/doctor/checks/fvm_check.dart`:
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
    final root = context.projectRoot;
    FvmPin? pin;
    if (root != null) {
      try {
        pin = readFvmPin(root);
      } on FormatException catch (error) {
        return CheckResult.error(error.message,
            fixHint: 'Run `fvm use <version>` to rewrite the pin.');
      }
    }
    if (pin == null) {
      return fvm == null
          ? const CheckResult.skipped('Not used by this project.')
          : CheckResult.info(
              'FVM is installed; this project does not pin a Flutter version.',
              details: ['fvm: $fvm']);
    }
    if (fvm == null) {
      return CheckResult.warning(
        'The project pins Flutter ${pin.version} with FVM, but `fvm` is not '
        'on PATH.',
        fixHint: 'Install FVM (https://fvm.app) so `fvm flutter` and '
            '`fvm dart` work.',
      );
    }
    return CheckResult.ok(
        'Project pins Flutter ${pin.version} (${p.basename(pin.configPath)})',
        details: ['fvm: $fvm']);
  }
}
```

`lib/src/doctor/checks/project_check.dart`:
```dart
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../../config/config_loader.dart';
import '../../sdk/language_version.dart';
import '../doctor_check.dart';

/// Checks the project: its `appstein.yaml` and Dart language version.
final class ProjectCheck implements DoctorCheck {
  /// Creates the check.
  const ProjectCheck();

  @override
  String get id => 'doctor.project';

  @override
  String get title => 'Project';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final root = context.projectRoot;
    if (root == null) {
      return const CheckResult.skipped('Not inside a Dart or Flutter project.');
    }
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    final language = pubspec.existsSync()
        ? languageVersionFromPubspec(pubspec.readAsStringSync())
        : null;
    final languageLine = language == null
        ? 'Dart language version: unknown (pubspec.yaml has no SDK lower bound)'
        : 'Dart language version: $language (from the SDK constraint in '
            'pubspec.yaml)';
    final AppsteinConfig? config;
    try {
      config = loadConfig(root);
    } on ConfigException catch (error) {
      return CheckResult.error('appstein.yaml is invalid: $error',
          details: [root],
          fixHint: 'Fix appstein.yaml at the position shown. Every key and '
              'its default are listed in section 7 of the Appstein spec.');
    }
    if (config == null) {
      return CheckResult.info(
          'No appstein.yaml: this project is not set up with Appstein yet.',
          details: [root, languageLine]);
    }
    return CheckResult.ok('appstein.yaml is valid', details: [
      root,
      'Stack: ${config.packs.stack}; platforms: '
          '${config.packs.platforms.join(', ')}',
      languageLine,
    ]);
  }
}
```

Add these exports to `lib/appstein_engine.dart`:
```dart
export 'src/doctor/check_helpers.dart';
export 'src/doctor/checks/dart_check.dart';
export 'src/doctor/checks/flutter_check.dart';
export 'src/doctor/checks/fvm_check.dart';
export 'src/doctor/checks/project_check.dart';
export 'src/doctor/doctor.dart';
export 'src/doctor/doctor_check.dart';
```

- [ ] **Step 7: Run the tests and the analyzer**

Run: `cd packages/appstein_engine; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add packages/appstein_engine
git commit -m "feat(engine): add the doctor framework with Flutter, Dart, FVM and project checks"
```

---

### Task 7: JDK and Android SDK checks

**Why this design:** most failed Android builds on a fresh machine come from Flutter quietly using a *different* JDK than the one `JAVA_HOME` names. The development machine shows this: Android Studio's JBR is broken while `JAVA_HOME` is a working JDK 21. So the check mirrors Flutter's own lookup order, and each lookup cites the `flutter_tools` source it copies. It then runs the JDK Flutter would pick.

**Files:**
- Create: `packages/appstein_engine/lib/src/android/{flutter_settings,java_locator,android_sdk_locator}.dart`
- Create: `packages/appstein_engine/lib/src/doctor/checks/{java_check,android_sdk_check}.dart`
- Create: `packages/appstein_engine/test/support/fake_android.dart`
- Test: `packages/appstein_engine/test/android/{flutter_settings_test,java_locator_test,android_sdk_locator_test}.dart`, `test/doctor/checks/{java_check_test,android_sdk_check_test}.dart`
- Modify: `lib/src/doctor/doctor.dart` (`defaultDoctorChecks`), `lib/appstein_engine.dart` (exports)

**Interfaces:**
- Consumes: Tasks 3 and 6.
- Produces:
  - `String? flutterSettingsPath(HostEnvironment)` and `Map<String, Object?> readFlutterSettings(HostEnvironment)`.
  - `enum JavaSource { flutterConfig, androidStudio, javaHome, path }`, each with a `label`.
  - `JavaLocation{javaBinary, source, home}` and `JavaLocation? locateFlutterJava(HostEnvironment, Map<String, Object?> settings)`.
  - `int? parseJavaMajor(String versionOutput)`.
  - `String? locateAndroidSdk(HostEnvironment, Map<String, Object?> settings)`.
  - `JavaCheck` (`doctor.java`) and `AndroidSdkCheck` (`doctor.android_sdk`).

- [ ] **Step 1: Write the failing tests**

`packages/appstein_engine/test/android/flutter_settings_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('Windows keeps the settings in %APPDATA%\\.flutter_settings', () {
    final env = fakeEnvironment({'APPDATA': 'appdata'}, os: HostOs.windows);
    expect(flutterSettingsPath(env), p.join('appdata', '.flutter_settings'));
  });

  test('macOS and Linux use ~/.flutter_settings when it exists', () {
    final home = tempDir();
    File(p.join(home.path, '.flutter_settings')).writeAsStringSync('{}');
    final env = fakeEnvironment({'HOME': home.path}, os: HostOs.linux);
    expect(flutterSettingsPath(env), p.join(home.path, '.flutter_settings'));
  });

  test(r'otherwise $XDG_CONFIG_HOME/settings, then ~/.config/flutter/settings',
      () {
    final home = tempDir().path;
    expect(
      flutterSettingsPath(
          fakeEnvironment({'HOME': home, 'XDG_CONFIG_HOME': 'xdg'}, os: HostOs.linux)),
      p.join('xdg', 'settings'),
    );
    expect(flutterSettingsPath(fakeEnvironment({'HOME': home}, os: HostOs.linux)),
        p.join(home, '.config', 'flutter', 'settings'));
  });

  test('reads the JSON and treats a broken file as empty', () {
    final dir = tempDir();
    final vars = Platform.isWindows ? {'APPDATA': dir.path} : {'HOME': dir.path};
    final file = File(p.join(dir.path, '.flutter_settings'))
      ..writeAsStringSync('{"jdk-dir": "C:/jdk"}');
    expect(readFlutterSettings(fakeEnvironment(vars)), {'jdk-dir': 'C:/jdk'});
    file.writeAsStringSync('{broken');
    expect(readFlutterSettings(fakeEnvironment(vars)), isEmpty);
  });
}
```

`packages/appstein_engine/test/support/fake_android.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates an Android Studio folder with a bundled JDK, laid out for this OS,
/// and returns the Android Studio folder.
String fakeStudio(Directory parent) {
  final studio = p.join(parent.path, 'Android Studio');
  File(p.join(studioJdkHome(studio), 'bin',
          Platform.isWindows ? 'java.exe' : 'java'))
      .createSync(recursive: true);
  return studio;
}

/// The JDK folder inside an Android Studio folder, for this OS.
String studioJdkHome(String studio) => Platform.isMacOS
    ? p.join(studio, 'Contents', 'jbr', 'Contents', 'Home')
    : p.join(studio, 'jbr');

/// A skip reason when this Mac or Linux machine has Android Studio in a
/// default folder, which the Java lookup would find. Null otherwise.
String? studioInstalledReason() {
  for (final dir in ['/Applications/Android Studio.app', '/opt/android-studio']) {
    if (Directory(dir).existsSync()) {
      return 'Android Studio is installed at $dir on this machine.';
    }
  }
  return null;
}
```

`packages/appstein_engine/test/android/java_locator_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fake_android.dart';
import '../support/temp.dart';

void main() {
  test('flutter config --jdk-dir wins', () {
    final location = locateFlutterJava(
        fakeEnvironment({'JAVA_HOME': 'jh'}), {'jdk-dir': 'configured'});
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, 'configured');
  });

  test("Android Studio's JDK comes before JAVA_HOME", () {
    final studio = fakeStudio(tempDir());
    final location = locateFlutterJava(
        fakeEnvironment({'JAVA_HOME': 'jh'}), {'android-studio-dir': studio});
    expect(location!.source, JavaSource.androidStudio);
  });

  test('then JAVA_HOME, then java on PATH', () {
    expect(locateFlutterJava(fakeEnvironment({'JAVA_HOME': 'jh'}), {})!.source,
        JavaSource.javaHome);
    final bin = tempDir();
    fakeExecutable(bin, 'java');
    final onPath = locateFlutterJava(
        fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}), {});
    expect(onPath!.source, JavaSource.path);
  });

  test('returns null when there is no JDK at all', () {
    expect(locateFlutterJava(fakeEnvironment({}), {}), isNull);
  });

  test('parses the major version from java -version output', () {
    expect(parseJavaMajor('openjdk version "21.0.2" 2024-01-16'), 21);
    expect(parseJavaMajor('java version "1.8.0_202"'), 8);
    expect(parseJavaMajor('openjdk version "17" 2021-09-14'), 17);
    expect(parseJavaMajor('openjdk 21.0.1 2023-10-17'), 21);
    expect(parseJavaMajor('garbage'), isNull);
  });
}
```

`packages/appstein_engine/test/android/android_sdk_locator_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

String fakeAndroidSdk(String root) {
  Directory(p.join(root, 'platform-tools')).createSync(recursive: true);
  return root;
}

void main() {
  test('the settings value wins over ANDROID_HOME', () {
    final a = fakeAndroidSdk(p.join(tempDir().path, 'a'));
    final b = fakeAndroidSdk(p.join(tempDir().path, 'b'));
    expect(
        locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': b}), {'android-sdk': a}),
        a);
  });

  test('ANDROID_HOME, then ANDROID_SDK_ROOT', () {
    final a = fakeAndroidSdk(p.join(tempDir().path, 'a'));
    expect(locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': a}), {}), a);
    expect(locateAndroidSdk(fakeEnvironment({'ANDROID_SDK_ROOT': a}), {}), a);
  });

  test('falls back to the default folder under the home folder', () {
    final home = tempDir().path;
    final defaultPath = switch (HostOs.current) {
      HostOs.windows => p.join(home, 'AppData', 'Local', 'Android', 'sdk'),
      HostOs.macos => p.join(home, 'Library', 'Android', 'sdk'),
      HostOs.linux => p.join(home, 'Android', 'Sdk'),
    };
    fakeAndroidSdk(defaultPath);
    final vars = Platform.isWindows ? {'USERPROFILE': home} : {'HOME': home};
    expect(locateAndroidSdk(fakeEnvironment(vars), {}), defaultPath);
  });

  test('a folder without licenses or platform-tools is not an SDK', () {
    final empty = tempDir().path;
    expect(locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': empty}), {}), isNull);
  });
}
```

`packages/appstein_engine/test/doctor/checks/java_check_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_android.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  late Directory settingsDir;
  late FakeProcessRunner runner;

  setUp(() {
    settingsDir = tempDir();
    runner = FakeProcessRunner();
  });

  Map<String, String> settings(Map<String, Object?> values,
      [Map<String, String> extra = const {}]) {
    File(p.join(settingsDir.path, '.flutter_settings')).writeAsStringSync(
        '{${values.entries.map((e) => '"${e.key}": "${e.value}"').join(', ')}}'
            .replaceAll(r'\', r'\\'));
    return {
      if (Platform.isWindows) 'APPDATA': settingsDir.path else 'HOME': settingsDir.path,
      ...extra,
    };
  }

  String javaIn(String home) =>
      p.join(home, 'bin', Platform.isWindows ? 'java.exe' : 'java');

  Future<CheckResult> run(Map<String, String> vars) => const JavaCheck()
      .run(testContext(environment: fakeEnvironment(vars), runner: runner));

  test('ok for a working JDK 17+ set with flutter config', () async {
    const home = 'configured jdk';
    runner.when(javaIn(home), ['-version'],
        const RunResult(exitCode: 0, stderr: 'openjdk version "21.0.2" 2024-01-16'));
    final result = await run(settings({'jdk-dir': home}));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('JDK 21'));
  });

  // The development machine on 2026-09-29: a broken Android Studio JBR.
  test("error when Android Studio's JDK does not run", () async {
    final studio = fakeStudio(tempDir());
    final home = studioJdkHome(studio);
    runner.when(javaIn(home), ['-version'],
        const RunResult(exitCode: 1, stderr: "Error: could not open `jvm.cfg'"));
    final result = await run(settings(
        {'android-studio-dir': studio}, {'JAVA_HOME': 'some other jdk'}));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('Android Studio'));
    expect(result.summary, contains('could not open'));
    expect(result.fixHint, contains('flutter config --jdk-dir'));
  });

  test('error for a JDK older than 17', () async {
    runner.when(javaIn('old jdk'), ['-version'],
        const RunResult(exitCode: 0, stderr: 'openjdk version "11.0.20" 2023-07-18'));
    final result = await run(settings({}, {'JAVA_HOME': 'old jdk'}));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('17'));
  });

  test('warning when Flutter uses a different JDK than JAVA_HOME', () async {
    final studio = fakeStudio(tempDir());
    final home = studioJdkHome(studio);
    runner.when(javaIn(home), ['-version'],
        const RunResult(exitCode: 0, stderr: 'openjdk version "21.0.6" 2025-01-21'));
    final result = await run(
        settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk-17'}));
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('JAVA_HOME'));
  });

  test('error when there is no JDK at all', () async {
    final result = await run(settings({}));
    expect(result.status, CheckStatus.error);
  });
}
```

`packages/appstein_engine/test/doctor/checks/android_sdk_check_test.dart`:
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

  void buildTools(String version, {bool zipalign = true}) {
    final dir = Directory(p.join(sdk, 'build-tools', version))
      ..createSync(recursive: true);
    if (zipalign) {
      File(p.join(dir.path, Platform.isWindows ? 'zipalign.exe' : 'zipalign'))
          .writeAsStringSync('');
    }
  }

  Future<CheckResult> run() => const AndroidSdkCheck()
      .run(testContext(environment: fakeEnvironment({'ANDROID_HOME': sdk})));

  test('ok with the newest stable build-tools and zipalign', () async {
    buildTools('35.0.0');
    buildTools('36.1.0');
    buildTools('37.0.0-rc2');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('36.1.0'));
  });

  test('warning when the newest build-tools has no zipalign', () async {
    buildTools('36.1.0', zipalign: false);
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(result.details.join('\n'), contains('zipalign'));
  });

  test('error without build-tools', () async {
    expect((await run()).status, CheckStatus.error);
  });

  test('error without any Android SDK', () async {
    final result = await const AndroidSdkCheck()
        .run(testContext(environment: fakeEnvironment({})));
    expect(result.status, CheckStatus.error);
    expect(result.fixHint, contains('ANDROID_HOME'));
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/android test/doctor/checks`
Expected: FAIL, because the new functions are undefined.

- [ ] **Step 3: Write `flutter_settings.dart`**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';

/// Where Flutter keeps the user settings that `flutter config` writes.
///
/// This mirrors `Config._configPath` in
/// `flutter_tools/lib/src/base/config.dart` (Flutter 3.47):
/// - Windows: `%APPDATA%\.flutter_settings`.
/// - macOS and Linux: `~/.flutter_settings` if it exists; otherwise
///   `$XDG_CONFIG_HOME/settings`, or `~/.config/flutter/settings` when
///   XDG_CONFIG_HOME is unset.
String? flutterSettingsPath(HostEnvironment environment) {
  if (environment.os == HostOs.windows) {
    final appData = environment.variable('APPDATA');
    return appData == null ? null : p.join(appData, '.flutter_settings');
  }
  final home = environment.variable('HOME');
  if (home == null) return null;
  final legacy = p.join(home, '.flutter_settings');
  if (File(legacy).existsSync()) return legacy;
  final configDir = environment.variable('XDG_CONFIG_HOME') ??
      p.join(home, '.config', 'flutter');
  return p.join(configDir, 'settings');
}

/// Flutter's user settings, such as `jdk-dir` and `android-sdk`. Empty when
/// the file is missing or unreadable.
Map<String, Object?> readFlutterSettings(HostEnvironment environment) {
  final path = flutterSettingsPath(environment);
  if (path == null) return const {};
  final file = File(path);
  if (!file.existsSync()) return const {};
  try {
    final data = jsonDecode(file.readAsStringSync());
    return data is Map<String, Object?> ? data : const {};
  } on FormatException {
    return const {};
  }
}
```

- [ ] **Step 4: Write `java_locator.dart`**

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/host_environment.dart';

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
  const JavaLocation({required this.javaBinary, required this.source, this.home});

  /// The `java` executable.
  final String javaBinary;

  /// Where it came from.
  final JavaSource source;

  /// The JDK folder, when known.
  final String? home;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`;
/// 2. Android Studio's bundled JDK;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// Flutter finds Android Studio through its install records. This checks the
/// `android-studio-dir` setting and the default install folders, which covers
/// standard installs.
JavaLocation? locateFlutterJava(
    HostEnvironment environment, Map<String, Object?> settings) {
  final configured = settings['jdk-dir'];
  if (configured is String && configured.isNotEmpty) {
    return JavaLocation(
        javaBinary: _javaIn(configured, environment),
        source: JavaSource.flutterConfig,
        home: configured);
  }
  final studioJdk = _androidStudioJdk(environment, settings);
  if (studioJdk != null) {
    return JavaLocation(
        javaBinary: _javaIn(studioJdk, environment),
        source: JavaSource.androidStudio,
        home: studioJdk);
  }
  final javaHome = environment.variable('JAVA_HOME');
  if (javaHome != null) {
    return JavaLocation(
        javaBinary: _javaIn(javaHome, environment),
        source: JavaSource.javaHome,
        home: javaHome);
  }
  final onPath = findExecutable('java', environment);
  return onPath == null
      ? null
      : JavaLocation(javaBinary: onPath, source: JavaSource.path);
}

/// The major Java version in `java -version` output: 21 for "21.0.2", and 8
/// for the old "1.8.0_202" style. Null when there is no version.
int? parseJavaMajor(String versionOutput) {
  final quoted = RegExp(r'version "(\d+)(?:\.(\d+))?').firstMatch(versionOutput);
  if (quoted != null) {
    final first = int.parse(quoted.group(1)!);
    final second = quoted.group(2);
    return first == 1 && second != null ? int.parse(second) : first;
  }
  final plain = RegExp(r'(?:openjdk|java) (\d+)').firstMatch(versionOutput);
  return plain == null ? null : int.parse(plain.group(1)!);
}

String _javaIn(String home, HostEnvironment environment) => p.join(
    home, 'bin', environment.os == HostOs.windows ? 'java.exe' : 'java');

String? _androidStudioJdk(
    HostEnvironment environment, Map<String, Object?> settings) {
  final studioDirs = <String>[
    if (settings['android-studio-dir'] case final String dir) dir,
    ..._defaultStudioDirs(environment),
  ];
  for (final studio in studioDirs) {
    final homes = environment.os == HostOs.macos
        ? [
            p.join(studio, 'Contents', 'jbr', 'Contents', 'Home'),
            p.join(studio, 'jbr', 'Contents', 'Home'),
          ]
        : [p.join(studio, 'jbr'), p.join(studio, 'jre')];
    for (final home in homes) {
      if (File(_javaIn(home, environment)).existsSync()) return home;
    }
  }
  return null;
}

List<String> _defaultStudioDirs(HostEnvironment environment) {
  final home = environment.homeDir;
  return switch (environment.os) {
    HostOs.windows => [
        p.join(environment.variable('ProgramFiles') ?? r'C:\Program Files',
            'Android', 'Android Studio'),
      ],
    HostOs.macos => ['/Applications/Android Studio.app'],
    HostOs.linux => [
        '/opt/android-studio',
        if (home != null) p.join(home, 'android-studio'),
      ],
  };
}
```

Note for the tests: `fakeEnvironment` (Task 3) points `ProgramFiles` at a folder that doesn't exist. Without that, the default-folder lookup would find the owner's real (broken) Android Studio and break the "JAVA_HOME" and "no JDK" tests.
- On macOS and Linux the default folders are absolute system paths. CI runners have no Android Studio there.
- On a developer Mac or Linux machine that *does* have one, guard those two tests with `skip: studioInstalledReason()` from `test/support/fake_android.dart`.

- [ ] **Step 5: Write `android_sdk_locator.dart`**

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';

/// Finds the Android SDK the way Flutter does (`locateAndroidSdk` in
/// `flutter_tools/lib/src/android/android_sdk.dart`, Flutter 3.47).
///
/// The first *defined* of `flutter config --android-sdk`, ANDROID_HOME,
/// ANDROID_SDK_ROOT and the default folder is used (or its `sdk` subfolder).
/// When that isn't a valid SDK, `adb` on PATH is tried. A folder is an SDK
/// when it has `licenses/` or `platform-tools/`.
String? locateAndroidSdk(
    HostEnvironment environment, Map<String, Object?> settings) {
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
  final adb = findExecutable('adb', environment);
  if (adb != null) {
    final root = p.dirname(p.dirname(resolveLinks(adb)));
    if (_isAndroidSdk(root)) return root;
  }
  return null;
}

String? _defaultAndroidSdk(HostEnvironment environment) {
  final home = environment.homeDir;
  if (home == null) return null;
  return switch (environment.os) {
    HostOs.windows => p.join(home, 'AppData', 'Local', 'Android', 'sdk'),
    HostOs.macos => p.join(home, 'Library', 'Android', 'sdk'),
    HostOs.linux => p.join(home, 'Android', 'Sdk'),
  };
}

bool _isAndroidSdk(String dir) =>
    Directory(p.join(dir, 'licenses')).existsSync() ||
    Directory(p.join(dir, 'platform-tools')).existsSync();
```

- [ ] **Step 6: Write the two checks**

`lib/src/doctor/checks/java_check.dart`:
```dart
import 'package:path/path.dart' as p;

import '../../android/flutter_settings.dart';
import '../../android/java_locator.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks the JDK Flutter actually uses for Android builds.
final class JavaCheck implements DoctorCheck {
  /// Creates the check.
  const JavaCheck();

  /// The oldest JDK that current Android Gradle Plugin versions accept.
  static const minimumMajor = 17;

  @override
  String get id => 'doctor.java';

  @override
  String get title => 'JDK used by Flutter';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final java = locateFlutterJava(environment, readFlutterSettings(environment));
    const pointFlutter = 'Point Flutter at a working JDK $minimumMajor or '
        'newer: `flutter config --jdk-dir "<path to the JDK>"`.';
    if (java == null) {
      return const CheckResult.error(
          'No JDK found. Android builds need JDK $minimumMajor or newer.',
          fixHint: 'Install JDK $minimumMajor or newer, then set JAVA_HOME or '
              'run `flutter config --jdk-dir "<path>"`.');
    }
    final where = '${java.source.label} (${java.home ?? java.javaBinary})';
    final details = ['Flutter checks, in order: `flutter config --jdk-dir`, '
        "Android Studio's JDK, JAVA_HOME, then `java` on PATH."];
    final result = await context.runner.run(java.javaBinary, ['-version']);
    if (!result.ok) {
      final reason = firstLine(result.stderr);
      return CheckResult.error(
        'Flutter uses $where, but it does not run: '
        '${reason.isEmpty ? 'exit code ${result.exitCode}' : reason}',
        details: details,
        fixHint: java.source == JavaSource.androidStudio
            ? 'Repair or reinstall Android Studio, or: $pointFlutter'
            : pointFlutter,
      );
    }
    final major = parseJavaMajor('${result.stderr}\n${result.stdout}');
    if (major == null) {
      return CheckResult.warning('Could not read the version of $where.',
          details: details, fixHint: pointFlutter);
    }
    if (major < minimumMajor) {
      return CheckResult.error(
          'Flutter uses JDK $major from $where; Android builds need '
          '$minimumMajor or newer.',
          details: details,
          fixHint: pointFlutter);
    }
    final javaHome = environment.variable('JAVA_HOME');
    final home = java.home;
    if (java.source != JavaSource.javaHome &&
        javaHome != null &&
        (home == null || !p.equals(javaHome, home))) {
      return CheckResult.warning(
        'Flutter uses JDK $major from $where, but JAVA_HOME points to '
        '$javaHome.',
        details: details,
        fixHint: 'Gradle run outside Flutter (such as ./gradlew) uses '
            'JAVA_HOME, so builds can behave differently. Point both at one '
            'JDK: `flutter config --jdk-dir "$javaHome"`, or change JAVA_HOME.',
      );
    }
    return CheckResult.ok('JDK $major from ${java.source.label}',
        details: ['Path: ${java.home ?? java.javaBinary}']);
  }
}
```

`lib/src/doctor/checks/android_sdk_check.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../android/android_sdk_locator.dart';
import '../../android/flutter_settings.dart';
import '../../host/host_environment.dart';
import '../doctor_check.dart';

/// Checks the Android SDK: build-tools, including `zipalign` for the 16 KB
/// page-size check, and `platform-tools`.
final class AndroidSdkCheck implements DoctorCheck {
  /// Creates the check.
  const AndroidSdkCheck();

  @override
  String get id => 'doctor.android_sdk';

  @override
  String get title => 'Android SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final sdk =
        locateAndroidSdk(environment, readFlutterSettings(environment));
    if (sdk == null) {
      return const CheckResult.error('No Android SDK found.',
          fixHint: 'Install Android Studio or the command-line tools, then '
              'run `flutter config --android-sdk "<path>"` or set ANDROID_HOME.');
    }
    final details = ['Path: $sdk'];
    final buildTools = _newestBuildTools(sdk);
    if (buildTools == null) {
      return CheckResult.error('The Android SDK has no build-tools.',
          details: details,
          fixHint: 'Install the latest build-tools in Android Studio '
              '(SDK Manager, SDK Tools tab).');
    }
    final problems = <String>[];
    final zipalign = environment.os == HostOs.windows ? 'zipalign.exe' : 'zipalign';
    if (!File(p.join(buildTools.path, zipalign)).existsSync()) {
      problems.add('build-tools ${buildTools.version} has no zipalign, so the '
          '16 KB page-size check will be skipped.');
    }
    if (!Directory(p.join(sdk, 'platform-tools')).existsSync()) {
      problems.add('platform-tools (adb) is missing, so apps can\'t be '
          'installed on devices.');
    }
    if (problems.isNotEmpty) {
      return CheckResult.warning(
          'Android SDK with build-tools ${buildTools.version}, but with gaps',
          details: [...details, ...problems],
          fixHint: 'Install the missing parts in Android Studio '
              '(SDK Manager, SDK Tools tab).');
    }
    return CheckResult.ok('Android SDK with build-tools ${buildTools.version}',
        details: details);
  }

  /// The newest stable build-tools, or the newest preview when there is no
  /// stable one.
  ({Version version, String path})? _newestBuildTools(String sdk) {
    final dir = Directory(p.join(sdk, 'build-tools'));
    if (!dir.existsSync()) return null;
    final all = <({Version version, String path})>[];
    for (final entry in dir.listSync().whereType<Directory>()) {
      try {
        all.add((version: Version.parse(p.basename(entry.path)), path: entry.path));
      } on FormatException {
        continue;
      }
    }
    if (all.isEmpty) return null;
    all.sort((a, b) => a.version.compareTo(b.version));
    final stable = all.where((b) => !b.version.isPreRelease);
    return stable.isNotEmpty ? stable.last : all.last;
  }
}
```

- [ ] **Step 7: Register the checks and export**

In `lib/src/doctor/doctor.dart`, add the imports and replace `defaultDoctorChecks`:
```dart
import 'checks/android_sdk_check.dart';
import 'checks/java_check.dart';
```
```dart
/// The checks `appstein doctor` runs, in the order they are shown.
List<DoctorCheck> defaultDoctorChecks() => const [
      FlutterCheck(),
      DartCheck(),
      FvmCheck(),
      JavaCheck(),
      AndroidSdkCheck(),
      ProjectCheck(),
    ];
```
Add these exports to `lib/appstein_engine.dart`:
```dart
export 'src/android/android_sdk_locator.dart';
export 'src/android/flutter_settings.dart';
export 'src/android/java_locator.dart';
export 'src/doctor/checks/android_sdk_check.dart';
export 'src/doctor/checks/java_check.dart';
```

- [ ] **Step 8: Run the tests and the analyzer**

Run: `cd packages/appstein_engine; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.

The real-machine check happens in Task 9, once `appstein doctor` exists. On the development machine, its JDK line must report the broken Android Studio JBR as an **error**.

- [ ] **Step 9: Commit (after the owner approves)**

```powershell
git add packages/appstein_engine
git commit -m "feat(engine): check the JDK Flutter really uses and the Android SDK"
```

---

### Task 8: Xcode, CocoaPods, git, ripgrep, agent CLIs and `appstein` on PATH

**Why the PATH check matters on Windows:** agent hooks call `appstein` by name. A PATH change made only in one terminal isn't seen by an agent started from the Start menu. So on Windows the check also reads the PATH saved in the registry, which every newly started program gets.

**Files:**
- Create: `packages/appstein_engine/lib/src/doctor/checks/{xcode_check,cocoapods_check,tool_check,agents_check,appstein_path_check}.dart`
- Test: `packages/appstein_engine/test/doctor/checks/{xcode_check_test,tool_check_test,agents_check_test,appstein_path_check_test}.dart`
- Modify: `lib/src/doctor/doctor.dart` (`defaultDoctorChecks`), `lib/appstein_engine.dart` (exports)

**Interfaces:**
- Consumes: Tasks 3, 5 and 6.
- Produces:
  - Checks: `XcodeCheck` (`doctor.xcode`), `CocoaPodsCheck` (`doctor.cocoapods`), `ToolCheck({id, title, command, why, installHints})`, `gitCheck` and `ripgrepCheck` (const `ToolCheck` values), `AgentsCheck` (`doctor.agents`) and `AppsteinPathCheck` (`doctor.appstein_path`).
  - Helpers: `bool isPubSnapshot(String path, HostEnvironment)`, `String? parseRegPathValue(String output)`, `String expandWindowsVariables(String value, HostEnvironment)` and `Future<List<String>?> savedWindowsPath(ProcessRunner, HostEnvironment)`.

- [ ] **Step 1: Write the failing tests**

`packages/appstein_engine/test/doctor/checks/xcode_check_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  late FakeProcessRunner runner;
  setUp(() => runner = FakeProcessRunner());

  Future<CheckResult> xcode(HostOs os) => const XcodeCheck().run(
      testContext(environment: fakeEnvironment({}, os: os), runner: runner));

  test('skipped outside macOS', () async {
    expect((await xcode(HostOs.windows)).status, CheckStatus.skipped);
  });

  test('ok for Xcode 26', () async {
    runner.when('xcodebuild', ['-version'],
        const RunResult(exitCode: 0, stdout: 'Xcode 26.0\nBuild version 17A324\n'));
    final result = await xcode(HostOs.macos);
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'Xcode 26.0');
  });

  test('error for Xcode older than 26', () async {
    runner.when('xcodebuild', ['-version'],
        const RunResult(exitCode: 0, stdout: 'Xcode 16.4\nBuild version 16F6\n'));
    expect((await xcode(HostOs.macos)).status, CheckStatus.error);
  });

  test('error when Xcode is missing', () async {
    expect((await xcode(HostOs.macos)).status, CheckStatus.error);
  });

  test('CocoaPods missing on macOS is only a warning', () async {
    final result = await const CocoaPodsCheck().run(testContext(
        environment: fakeEnvironment({}, os: HostOs.macos), runner: runner));
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('2026-12-02'));
  });
}
```

`packages/appstein_engine/test/doctor/checks/tool_check_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('ok with the first line of --version', () async {
    final bin = tempDir();
    final git = fakeExecutable(bin, 'git');
    final runner = FakeProcessRunner()
      ..when(git, ['--version'],
          const RunResult(exitCode: 0, stdout: 'git version 2.47.1\n'));
    final result = await gitCheck.run(testContext(
        environment: fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
        runner: runner));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'git version 2.47.1');
  });

  test('missing is a warning that says why and how to install', () async {
    final result = await ripgrepCheck.run(testContext());
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('Dart MCP server'));
    expect(result.fixHint, isNotEmpty);
  });
}
```

`packages/appstein_engine/test/doctor/checks/agents_check_test.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('warning when no supported agent CLI is installed', () async {
    final result = await const AgentsCheck().run(testContext());
    expect(result.status, CheckStatus.warning);
  });

  test('ok when one is installed, and it only asks for the version', () async {
    final bin = tempDir();
    final claude = fakeExecutable(bin, 'claude');
    final runner = FakeProcessRunner()
      ..when(claude, ['--version'],
          const RunResult(exitCode: 0, stdout: '2.1.3 (Claude Code)\n'));
    final result = await const AgentsCheck().run(testContext(
        environment: fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
        runner: runner));
    expect(result.status, CheckStatus.ok);
    expect(result.details.join('\n'), contains('Codex: not installed'));
    // Never touch credentials: only `--version` may run.
    expect(runner.calls, everyElement(endsWith('--version')));
  });
}
```

`packages/appstein_engine/test/doctor/checks/appstein_path_check_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('warning when appstein is not on PATH', () async {
    final result = await const AppsteinPathCheck().run(testContext());
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('not on PATH'));
  });

  test('recognizes pub global snapshots', () {
    final env = fakeEnvironment({});
    expect(isPubSnapshot(p.join('C:', 'Users', 'a', 'AppData', 'Local', 'Pub',
        'Cache', 'bin', 'appstein.bat'), env), isTrue);
    expect(isPubSnapshot(p.join('home', 'a', '.pub-cache', 'bin', 'appstein'), env),
        isTrue);
    expect(isPubSnapshot(p.join('opt', 'appstein', 'appstein'), env), isFalse);
  });

  test('reads the Path value from reg query output', () {
    const output = '\r\nHKEY_CURRENT_USER\\Environment\r\n'
        '    Path    REG_EXPAND_SZ    %USERPROFILE%\\bin;C:\\tools\r\n\r\n';
    expect(parseRegPathValue(output), r'%USERPROFILE%\bin;C:\tools');
    expect(parseRegPathValue('ERROR: not found'), isNull);
  });

  test('expands %VARIABLES% and keeps unknown ones', () {
    final env = fakeEnvironment({'USERPROFILE': r'C:\Users\a'}, os: HostOs.windows);
    expect(expandWindowsVariables(r'%USERPROFILE%\bin;%NOPE%\x', env),
        r'C:\Users\a\bin;%NOPE%\x');
  });

  group('on Windows', () {
    late Directory bin;
    late FakeProcessRunner runner;

    setUp(() {
      bin = tempDir();
      File(p.join(bin.path, 'appstein.exe')).writeAsStringSync('');
      runner = FakeProcessRunner();
    });

    void savedUserPath(String value) => runner.when(
        'reg',
        ['query', r'HKCU\Environment', '/v', 'Path'],
        RunResult(exitCode: 0, stdout: '    Path    REG_SZ    $value\r\n'));

    Future<CheckResult> run() => const AppsteinPathCheck().run(testContext(
        environment: fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
        runner: runner));

    test('ok when the folder is also on the saved PATH', () async {
      savedUserPath(bin.path);
      expect((await run()).status, CheckStatus.ok);
    });

    test('warning when only this terminal has it on PATH', () async {
      savedUserPath(r'C:\somewhere\else');
      final result = await run();
      expect(result.status, CheckStatus.warning);
      expect(result.summary, contains('saved'));
    });
  }, testOn: 'windows');
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/appstein_engine; fvm dart test test/doctor/checks`
Expected: FAIL, because the new checks are undefined.

- [ ] **Step 3: Write `xcode_check.dart` and `cocoapods_check.dart`**

`xcode_check.dart`:
```dart
import '../../host/host_environment.dart';
import '../../sdk/supported_versions.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks Xcode on macOS. App Store uploads need Xcode 26 or newer.
final class XcodeCheck implements DoctorCheck {
  /// Creates the check.
  const XcodeCheck();

  @override
  String get id => 'doctor.xcode';

  @override
  String get title => 'Xcode';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (context.environment.os != HostOs.macos) {
      return const CheckResult.skipped('iOS builds need macOS. On this '
          'machine iOS checks are static; CI builds iOS on macOS.');
    }
    final result = await context.runner.run('xcodebuild', ['-version']);
    if (!result.ok) {
      return const CheckResult.error('Xcode not found.',
          fixHint: 'Install Xcode $minimumXcodeMajor or newer from the App '
              'Store, then run `sudo xcode-select -s /Applications/Xcode.app`.');
    }
    final match = RegExp(r'Xcode (\d+)(?:\.\d+)*').firstMatch(result.stdout);
    if (match == null) {
      return CheckResult.warning('Could not read the Xcode version.',
          details: [firstLine(result.stdout)]);
    }
    final version = match.group(0)!;
    if (int.parse(match.group(1)!) < minimumXcodeMajor) {
      return CheckResult.error(
          '$version is too old: App Store uploads need Xcode '
          '$minimumXcodeMajor or newer (since 2026-04-28).',
          fixHint: 'Update Xcode from the App Store.');
    }
    return CheckResult.ok(version);
  }
}
```

`cocoapods_check.dart`:
```dart
import '../../host/host_environment.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks CocoaPods on macOS. Swift Package Manager is the default now, but
/// plugins without SwiftPM support still need CocoaPods.
final class CocoaPodsCheck implements DoctorCheck {
  /// Creates the check.
  const CocoaPodsCheck();

  @override
  String get id => 'doctor.cocoapods';

  @override
  String get title => 'CocoaPods';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (context.environment.os != HostOs.macos) {
      return const CheckResult.skipped('Only used for iOS builds on macOS.');
    }
    final result = await context.runner.run('pod', ['--version']);
    if (!result.ok) {
      return const CheckResult.warning(
          'CocoaPods not found. Plugins without Swift Package Manager support '
          'still need it (CocoaPods trunk becomes read-only on 2026-12-02).',
          fixHint: 'brew install cocoapods');
    }
    return CheckResult.ok('CocoaPods ${firstLine(result.stdout)}');
  }
}
```

- [ ] **Step 4: Write `tool_check.dart` and `agents_check.dart`**

`tool_check.dart`:
```dart
import '../../host/executable_finder.dart';
import '../../host/host_environment.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks that a command-line tool is installed, and shows its version.
final class ToolCheck implements DoctorCheck {
  /// Creates a check for [command].
  const ToolCheck({
    required this.id,
    required this.title,
    required this.command,
    required this.why,
    required this.installHints,
  });

  @override
  final String id;

  @override
  final String title;

  /// The command, looked up on PATH.
  final String command;

  /// Why Appstein needs it. Shown when it is missing.
  final String why;

  /// How to install it on each OS.
  final Map<HostOs, String> installHints;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final path = findExecutable(command, context.environment);
    if (path == null) {
      return CheckResult.warning('`$command` not found. $why',
          fixHint: installHints[context.environment.os]);
    }
    final result = await context.runner.run(path, ['--version']);
    return CheckResult.ok(
        result.ok ? firstLine(result.stdout) : '$command (version unknown)',
        details: ['Path: $path']);
  }
}

/// git: `create` proposes the first commit and `upgrade` refuses a dirty tree.
const gitCheck = ToolCheck(
  id: 'doctor.git',
  title: 'git',
  command: 'git',
  why: 'Appstein uses it to propose commits and to protect upgrades.',
  installHints: {
    HostOs.windows: 'winget install Git.Git',
    HostOs.macos: 'xcode-select --install',
    HostOs.linux: 'Install git with your package manager, e.g. `sudo apt install git`.',
  },
);

/// ripgrep: the Dart MCP server's package search needs it.
const ripgrepCheck = ToolCheck(
  id: 'doctor.ripgrep',
  title: 'ripgrep',
  command: 'rg',
  why: 'The Dart MCP server uses it to search package sources.',
  installHints: {
    HostOs.windows: 'winget install BurntSushi.ripgrep.MSVC',
    HostOs.macos: 'brew install ripgrep',
    HostOs.linux: 'Install ripgrep with your package manager, e.g. '
        '`sudo apt install ripgrep`.',
  },
);
```

`agents_check.dart`:
```dart
import '../../host/executable_finder.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks which supported agent CLIs are installed. It only runs
/// `--version`; Appstein never touches agent logins (spec §4, principle 6).
final class AgentsCheck implements DoctorCheck {
  /// Creates the check.
  const AgentsCheck();

  static const _agents = [('claude', 'Claude Code'), ('codex', 'Codex')];

  @override
  String get id => 'doctor.agents';

  @override
  String get title => 'Agent CLIs';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final found = <String>[];
    final details = <String>[];
    for (final (command, name) in _agents) {
      final path = findExecutable(command, context.environment);
      if (path == null) {
        details.add('$name: not installed');
        continue;
      }
      final result = await context.runner
          .run(path, ['--version'], timeout: const Duration(seconds: 10));
      found.add(name);
      details.add('$name: ${result.ok ? firstLine(result.stdout) : 'version '
          'unknown'} ($path)');
    }
    if (found.isEmpty) {
      return CheckResult.warning(
          'No supported agent CLI found (Claude Code or Codex).',
          details: details,
          fixHint: 'Install Claude Code or Codex and log in through its own '
              'command. Appstein never handles your login.');
    }
    return CheckResult.ok('${found.join(' and ')} found', details: details);
  }
}
```

- [ ] **Step 5: Write `appstein_path_check.dart`**

```dart
import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../host/host_environment.dart';
import '../../host/process_runner.dart';
import '../doctor_check.dart';

/// Checks that agent hooks can find the `appstein` command (spec §5.3).
final class AppsteinPathCheck implements DoctorCheck {
  /// Creates the check.
  const AppsteinPathCheck();

  @override
  String get id => 'doctor.appstein_path';

  @override
  String get title => 'appstein on PATH';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final current = findExecutable('appstein', environment);
    if (current == null) {
      return const CheckResult.warning(
          '`appstein` is not on PATH. Agent hooks call it by name, so they '
          'would fail.',
          fixHint: 'Add the folder that contains the appstein executable to '
              'your PATH, then restart your terminal and your agent.');
    }
    final details = ['Path: $current'];
    if (isPubSnapshot(current, environment)) {
      return CheckResult.warning(
          '`appstein` runs through a pub snapshot, which starts slowly. '
          'Hooks run it after every edit.',
          details: details,
          fixHint: 'Install the standalone binary from the GitHub release.');
    }
    if (environment.os == HostOs.windows) {
      final saved = await savedWindowsPath(context.runner, environment);
      final folder = p.dirname(current);
      if (saved != null && !saved.any((dir) => p.equals(dir, folder))) {
        return CheckResult.warning(
          '`appstein` is on this terminal\'s PATH, but not on your saved user '
          'or system PATH, so an agent started from elsewhere won\'t find it.',
          details: details,
          fixHint: 'Add $folder to your user PATH (Settings > System > About > '
              'Advanced system settings > Environment Variables), then '
              'restart the agent.',
        );
      }
    }
    return CheckResult.ok('appstein is on PATH', details: details);
  }
}

/// Whether [path] is a `dart pub global activate` launcher:
/// `%LOCALAPPDATA%\Pub\Cache\bin` on Windows, `~/.pub-cache/bin` elsewhere,
/// or anywhere under PUB_CACHE.
bool isPubSnapshot(String path, HostEnvironment environment) {
  final pubCache = environment.variable('PUB_CACHE');
  if (pubCache != null && p.isWithin(pubCache, path)) return true;
  final parts = p.split(p.dirname(path)).map((s) => s.toLowerCase()).toList();
  final n = parts.length;
  if (n < 2 || parts[n - 1] != 'bin') return false;
  return parts[n - 2] == '.pub-cache' ||
      (n >= 3 && parts[n - 2] == 'cache' && parts[n - 3] == 'pub');
}

/// The data of the `Path` value in `reg query ... /v Path` output.
String? parseRegPathValue(String output) => RegExp(
        r'^\s*Path\s+REG_(?:EXPAND_)?SZ\s+(.*)$',
        multiLine: true,
        caseSensitive: false)
    .firstMatch(output)
    ?.group(1)
    ?.trim();

/// Expands `%NAME%` references with [environment], leaving unknown ones.
String expandWindowsVariables(String value, HostEnvironment environment) =>
    value.replaceAllMapped(RegExp('%([^%]+)%'),
        (m) => environment.variable(m.group(1)!) ?? m.group(0)!);

/// The user and system PATH saved in the Windows registry, with `%NAME%`
/// references expanded. Programs started from now on get this PATH. Null
/// when neither can be read.
Future<List<String>?> savedWindowsPath(
    ProcessRunner runner, HostEnvironment environment) async {
  const keys = [
    r'HKCU\Environment',
    r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
  ];
  final dirs = <String>[];
  var readAny = false;
  for (final key in keys) {
    final result = await runner.run('reg', ['query', key, '/v', 'Path']);
    final value = result.ok ? parseRegPathValue(result.stdout) : null;
    if (value == null) continue;
    readAny = true;
    for (final entry in value.split(';')) {
      final dir = expandWindowsVariables(entry.trim(), environment);
      if (dir.isNotEmpty) dirs.add(dir);
    }
  }
  return readAny ? dirs : null;
}
```

- [ ] **Step 6: Register the checks and export**

In `doctor.dart`, add the imports for the five new files and replace `defaultDoctorChecks`:
```dart
/// The checks `appstein doctor` runs, in the order they are shown.
List<DoctorCheck> defaultDoctorChecks() => const [
      FlutterCheck(),
      DartCheck(),
      FvmCheck(),
      JavaCheck(),
      AndroidSdkCheck(),
      XcodeCheck(),
      CocoaPodsCheck(),
      gitCheck,
      ripgrepCheck,
      AgentsCheck(),
      AppsteinPathCheck(),
      ProjectCheck(),
    ];
```
Add the five `export 'src/doctor/checks/…';` lines to `lib/appstein_engine.dart`, keeping them sorted.

- [ ] **Step 7: Run the tests and the analyzer**

Run: `cd packages/appstein_engine; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` (the Windows group runs only on Windows) and no issues.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add packages/appstein_engine
git commit -m "feat(engine): check Xcode, CocoaPods, git, ripgrep, agent CLIs and appstein on PATH"
```

---

### Task 9: The `appstein` CLI: `--version`, `--project`, `doctor` and exit codes

**Why this design:** `runAppstein()` returns an exit code instead of calling `exit()`, and it writes to injected sinks. That keeps the whole CLI testable in-process. Every failure maps to the spec's exit codes, and an unexpected crash prints what to do next instead of only a stack trace.

**Files:**
- Create: `packages/appstein_cli/bin/appstein.dart`
- Create: `packages/appstein_cli/lib/src/{exit_codes,version,project_option,doctor_printer,doctor_command,runner}.dart`
- Modify: `packages/appstein_cli/lib/appstein_cli.dart`
- Test: `packages/appstein_cli/test/{version_test,runner_test,doctor_printer_test}.dart`

**Interfaces:**
- Consumes: Tasks 3–8 (`Doctor`, `DoctorReport`, `DoctorCheck`, `CheckResult`, `CheckStatus`, `HostEnvironment`, `ProcessRunner`, `SystemProcessRunner`, `findProjectRoot`, `ConfigException`, `minSupportedFlutter`, `newestKnownFlutterMinor`); `protocolVersion` (Task 2).
- Produces:
  - `Future<int> runAppstein(List<String> arguments, {StringSink? out, StringSink? err, HostEnvironment? environment, ProcessRunner? processRunner, List<DoctorCheck>? doctorChecks, List<Command<int>> extraCommands = const []})`. The last two parameters are for tests.
  - `abstract final class ExitCodes { ok = 0; errorsFound = 1; appsteinFailed = 3; }`.
  - `const appsteinVersion`, `String versionText()` and `String formatDoctorReport(DoctorReport report, {String? projectRoot})`.

- [ ] **Step 1: Write the failing tests**

`packages/appstein_cli/test/version_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  // An AOT binary can't read pubspec.yaml at run time, so the version is a
  // constant. This test keeps the two in step. Run it from the package folder.
  test('appsteinVersion matches pubspec.yaml', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(appsteinVersion, pubspec['version']);
  });
}
```

`packages/appstein_cli/test/runner_test.dart`:
```dart
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Check implements DoctorCheck {
  const _Check(this.result);

  final CheckResult result;

  @override
  String get id => 'test.check';

  @override
  String get title => 'Test check';

  @override
  Future<CheckResult> run(DoctorContext context) async => result;
}

final class _CrashCommand extends Command<int> {
  @override
  String get name => 'crash';

  @override
  String get description => 'Throws, for tests.';

  @override
  Future<int> run() async => throw StateError('simulated crash');
}

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Directory work;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    work = Directory.systemTemp.createTempSync('appstein cli tëst ');
    addTearDown(() => work.deleteSync(recursive: true));
  });

  Future<int> run(List<String> args,
          {List<DoctorCheck>? checks, List<Command<int>> extra = const []}) =>
      runAppstein(args,
          out: out,
          err: err,
          environment: HostEnvironment(
              os: HostOs.current, variables: const {}, workingDirectory: work.path),
          doctorChecks: checks,
          extraCommands: extra);

  test('--version prints the versions and exits 0', () async {
    expect(await run(['--version']), ExitCodes.ok);
    expect(out.toString(), contains('appstein $appsteinVersion'));
    expect(out.toString(), contains('protocol 1'));
    expect(out.toString(), contains('flutter >=3.44.0'));
  });

  test('an unknown option exits 3 and shows usage', () async {
    expect(await run(['--nope']), ExitCodes.appsteinFailed);
    expect(err.toString(), contains('Could not find an option named'));
  });

  test('doctor exits 1 when a check finds an error', () async {
    final code = await run(['doctor'],
        checks: [const _Check(CheckResult.error('broken', fixHint: 'fix it'))]);
    expect(code, ExitCodes.errorsFound);
    expect(out.toString(), contains('[error] Test check: broken'));
    expect(out.toString(), contains('Fix: fix it'));
  });

  test('doctor exits 0 with only warnings', () async {
    final code = await run(['doctor'],
        checks: [const _Check(CheckResult.warning('meh'))]);
    expect(code, ExitCodes.ok);
  });

  test('--project must point at a folder with pubspec.yaml', () async {
    final code = await run(['--project', p.join(work.path, 'missing'), 'doctor'],
        checks: const []);
    expect(code, ExitCodes.appsteinFailed);
    expect(err.toString(), contains('No pubspec.yaml'));
  });

  test('--project accepts a relative path with spaces', () async {
    Directory(p.join(work.path, 'my app')).createSync();
    File(p.join(work.path, 'my app', 'pubspec.yaml')).writeAsStringSync('name: a');
    final code = await run(['--project', 'my app', 'doctor'], checks: const []);
    expect(code, ExitCodes.ok);
    expect(out.toString(), contains(p.join(work.path, 'my app')));
  });

  test('a crash exits 3 and says what to do', () async {
    final code = await run(['crash'], extra: [_CrashCommand()]);
    expect(code, ExitCodes.appsteinFailed);
    expect(err.toString(), contains('simulated crash'));
    expect(err.toString(), contains('appstein doctor'));
  });
}
```

`packages/appstein_cli/test/doctor_printer_test.dart`:
```dart
import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

final class _Named implements DoctorCheck {
  const _Named(this.title);

  @override
  final String title;

  @override
  String get id => 'x';

  @override
  Future<CheckResult> run(DoctorContext context) => throw UnimplementedError();
}

void main() {
  test('prints aligned ASCII labels, details, fixes and a summary', () {
    final text = formatDoctorReport(
      const DoctorReport([
        DoctorEntry(_Named('Flutter SDK'),
            CheckResult.ok('Flutter 3.47.5 (stable)', details: ['Found']))),
        DoctorEntry(_Named('JDK'),
            CheckResult.error('broken', fixHint: 'repair it')),
        DoctorEntry(_Named('git'), CheckResult.warning('old')),
      ]),
      projectRoot: '/work/app',
    );
    expect(text, contains('Project: /work/app'));
    expect(text, contains('[ok]    Flutter SDK: Flutter 3.47.5 (stable)'));
    expect(text, contains('        Found'));
    expect(text, contains('[error] JDK: broken'));
    expect(text, contains('        Fix: repair it'));
    expect(text, contains('Summary: 1 error, 1 warning.'));
    expect(text.codeUnits.every((c) => c < 128), isTrue);
  });

  test('says so when nothing is wrong, and when there is no project', () {
    final text = formatDoctorReport(const DoctorReport([]));
    expect(text, contains('Project: none found here'));
    expect(text, contains('No problems found.'));
  });
}
```

`DoctorEntry` and `DoctorReport` need `const` constructors for this test. They already have them (Task 6).

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/appstein_cli; fvm dart test`
Expected: FAIL, because `runAppstein` and friends are undefined.

- [ ] **Step 3: Write the small files**

`lib/src/exit_codes.dart`:
```dart
/// Exit codes shared by every command (spec §9.5).
abstract final class ExitCodes {
  /// No errors.
  static const ok = 0;

  /// Errors found. Used by the CLI and CI.
  static const errorsFound = 1;

  /// Appstein itself failed: bad usage, a bad environment or a crash.
  static const appsteinFailed = 3;
}
```

`lib/src/version.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// This build's version. It must match `version:` in pubspec.yaml; a test
/// checks that.
const appsteinVersion = '0.1.0-dev';

/// The text `appstein --version` prints: the Appstein version, the protocol
/// version and the supported Flutter range.
String versionText() => [
      'appstein $appsteinVersion',
      'protocol $protocolVersion',
      'flutter >=$minSupportedFlutter (built for up to $newestKnownFlutterMinor)',
    ].join('\n');
```

`lib/src/project_option.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

/// Resolves the global `--project` option.
///
/// An explicit path, relative to the working folder, must contain
/// `pubspec.yaml`. Without the option, the nearest folder at or above the
/// working folder that contains one is used (null when there is none).
String? resolveProjectRoot(ArgResults? globalResults, HostEnvironment environment) {
  final explicit = globalResults?.option('project');
  if (explicit == null) return findProjectRoot(environment.workingDirectory);
  final root = p.normalize(p.join(environment.workingDirectory, explicit));
  if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
    throw UsageException('No pubspec.yaml in $root.',
        'Pass --project the folder of a Dart or Flutter project.');
  }
  return root;
}
```

- [ ] **Step 4: Write `doctor_printer.dart` and `doctor_command.dart`**

`lib/src/doctor_printer.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';

/// Formats a doctor report as plain text.
///
/// Status labels are ASCII, so the output reads correctly in any Windows
/// console code page.
String formatDoctorReport(DoctorReport report, {String? projectRoot}) {
  const indent = '        ';
  final buffer = StringBuffer()
    ..writeln('Appstein doctor')
    ..writeln(projectRoot == null
        ? 'Project: none found here; project checks are skipped.'
        : 'Project: $projectRoot')
    ..writeln();
  var errors = 0;
  var warnings = 0;
  for (final entry in report.entries) {
    final result = entry.result;
    if (result.status == CheckStatus.error) errors++;
    if (result.status == CheckStatus.warning) warnings++;
    buffer.writeln(
        '${_label(result.status).padRight(8)}${entry.check.title}: ${result.summary}');
    for (final detail in result.details) {
      buffer.writeln('$indent$detail');
    }
    final fix = result.fixHint;
    if (fix != null &&
        (result.status == CheckStatus.error ||
            result.status == CheckStatus.warning)) {
      buffer.writeln('${indent}Fix: $fix');
    }
  }
  buffer
    ..writeln()
    ..writeln(errors == 0 && warnings == 0
        ? 'No problems found.'
        : 'Summary: ${_count(errors, 'error')}, ${_count(warnings, 'warning')}.');
  return buffer.toString();
}

String _label(CheckStatus status) => switch (status) {
      CheckStatus.ok => '[ok]',
      CheckStatus.info => '[info]',
      CheckStatus.warning => '[warn]',
      CheckStatus.error => '[error]',
      CheckStatus.skipped => '[skip]',
    };

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
```

`lib/src/doctor_command.dart`:
```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';

import 'doctor_printer.dart';
import 'exit_codes.dart';
import 'project_option.dart';

/// `appstein doctor`: checks the environment and explains fixes.
final class DoctorCommand extends Command<int> {
  /// Creates the command.
  DoctorCommand({
    required this.out,
    required this.environment,
    required this.processRunner,
    this.checks,
  });

  /// Where the report goes.
  final StringSink out;

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner processRunner;

  /// The checks to run; null means the default checks.
  final List<DoctorCheck>? checks;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check your environment and explain how to fix problems.';

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    final report = await Doctor(
            environment: environment, runner: processRunner, checks: checks)
        .run(projectRoot: projectRoot);
    out.write(formatDoctorReport(report, projectRoot: projectRoot));
    return report.hasErrors ? ExitCodes.errorsFound : ExitCodes.ok;
  }
}
```

- [ ] **Step 5: Write `runner.dart`, the barrel and `bin/appstein.dart`**

`lib/src/runner.dart`:
```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'doctor_command.dart';
import 'exit_codes.dart';
import 'version.dart';

/// Runs the `appstein` command line and returns the process exit code
/// (spec §9.5).
///
/// [out] and [err] default to stdout and stderr, and [environment] and
/// [processRunner] default to the real machine. [doctorChecks] and
/// [extraCommands] exist only for tests: they replace the doctor's checks
/// and add commands, such as one that crashes on purpose.
Future<int> runAppstein(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  HostEnvironment? environment,
  ProcessRunner? processRunner,
  List<DoctorCheck>? doctorChecks,
  List<Command<int>> extraCommands = const [],
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final runner = _AppsteinCommandRunner(output)
    ..addCommand(DoctorCommand(
      out: output,
      environment: environment ?? HostEnvironment.current(),
      processRunner: processRunner ?? const SystemProcessRunner(),
      checks: doctorChecks,
    ));
  extraCommands.forEach(runner.addCommand);
  try {
    return await runner.run(arguments) ?? ExitCodes.ok;
  } on UsageException catch (error) {
    errors
      ..writeln(error.message)
      ..writeln()
      ..writeln(error.usage);
    return ExitCodes.appsteinFailed;
  } on ConfigException catch (error) {
    errors.writeln('Invalid appstein.yaml: $error');
    return ExitCodes.appsteinFailed;
  } catch (error, stackTrace) {
    errors
      ..writeln('Appstein failed unexpectedly: $error')
      ..writeln('Run `appstein doctor` to check your setup. If this keeps '
          'happening, please report it with the details below.')
      ..writeln(stackTrace);
    return ExitCodes.appsteinFailed;
  }
}

final class _AppsteinCommandRunner extends CommandRunner<int> {
  _AppsteinCommandRunner(this._out)
      : super('appstein',
            'A knowledge and verification layer for AI agents that build '
            'Flutter apps.') {
    argParser
      ..addFlag('version',
          negatable: false,
          help: 'Print the Appstein, protocol and supported Flutter versions.')
      ..addOption('project',
          valueHelp: 'path',
          help: 'The Flutter project to work on. Defaults to the nearest '
              'folder at or above the current one that contains pubspec.yaml.');
  }

  final StringSink _out;

  @override
  void printUsage() => _out.writeln(usage);

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults.flag('version')) {
      _out.writeln(versionText());
      return ExitCodes.ok;
    }
    return super.runCommand(topLevelResults);
  }
}
```

`lib/appstein_cli.dart`:
```dart
/// The `appstein` command-line tool.
library;

export 'src/doctor_printer.dart';
export 'src/exit_codes.dart';
export 'src/runner.dart';
export 'src/version.dart';
```

`bin/appstein.dart`:
```dart
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';

Future<void> main(List<String> arguments) async {
  // Setting exitCode (instead of calling exit()) lets stdout finish flushing,
  // which matters on Windows consoles.
  exitCode = await runAppstein(arguments);
}
```

- [ ] **Step 6: Run the tests and the analyzer**

Run: `cd packages/appstein_cli; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.

- [ ] **Step 7: Run it for real on the development machine**

```powershell
fvm dart run packages/appstein_cli/bin/appstein.dart --version
fvm dart run packages/appstein_cli/bin/appstein.dart doctor
$LASTEXITCODE
```
Expected, on the development machine (2026-09-29 state):
- `[ok]    Flutter SDK: Flutter 3.47.5 (stable)`, found through FVM (the repo has `.fvmrc`).
- `[info]  Dart SDK`, noting that PATH `dart` is a different SDK.
- `[error] JDK used by Flutter:` with "Android Studio's bundled JDK … does not run: Error: could not open `…jvm.cfg'".
- `[warn]  appstein on PATH: … not on PATH`.
- `[info]  Project: No appstein.yaml …`.
- The exit code is `1`, because of the JDK error.

If anything differs, fix the code (or, if the expectation is wrong, tell the owner why), then show the owner the output. The JDK error is real, and the owner may want to fix it with `flutter config --jdk-dir "C:\Program Files\Java\jdk-21"`.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add packages/appstein_cli
git commit -m "feat(cli): add appstein --version, --project and doctor with spec exit codes"
```

---

### Task 10: The `layer_imports` analyzer rule

**Why this design:**
- The rule reads its config through the **analyzer's** file API (`package:analyzer/file_system`), not `dart:io`. That way it sees unsaved editor changes, and tests can run it on an in-memory file system.
- It finds the nearest `analysis_options.yaml` **that has an `appstein_lints:` section**, walking up from the analyzed file. In a pub workspace, the analyzer's "package root" is the member package, so walking up is required (see the Evidence section).
- The parsed config is cached by file modification stamp, because the rule runs for every file.
- A broken config is reported on each file as a clear diagnostic, never silently ignored.
- The rule checks `export` directives as well as imports, because a re-export leaks a layer just as an import does.

The `official_mvvm` rule that `ui` may use repositories only through their abstract interfaces (spec §9.6) is a pack detail, and it lands with the pack in 1b and 1d. This task builds the generic tag rule.

**Files:**
- Create: `packages/appstein_lints/lib/src/layer_imports/{layer_config,layer_matcher,layer_imports_rule}.dart`
- Create: `packages/appstein_lints/lib/src/appstein_lints_plugin.dart`
- Modify: `packages/appstein_lints/lib/main.dart`
- Test: `packages/appstein_lints/test/layer_matcher_test.dart`, `test/layer_imports_rule_test.dart`

**Interfaces:**
- Consumes: `LayerRules` (Task 2).
- Produces:
  - `LayerConfig{optionsPath, rootPath, LayerRules? rules, String? error}`, and `LayerConfigFinder`, with `LayerConfig? find(File file)`, where `File` is from `package:analyzer/file_system/file_system.dart`.
  - `LayerMatcher(LayerRules)`, with `String? tagFor(String relativePosixPath)`.
  - `LayerImportsRule` (a `MultiAnalysisRule` named `layer_imports`), whose codes are `forbiddenImport` and `invalidConfig`.
  - `AppsteinLintsPlugin`, and the top-level `plugin` in `lib/main.dart`.

- [ ] **Step 1: Write the failing tests**

`packages/appstein_lints/test/layer_matcher_test.dart`:
```dart
import 'package:appstein_lints/src/layer_imports/layer_matcher.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final matcher = LayerMatcher(LayerRules.fromJson({
    'layers': {
      'test': ['packages/*/test/**'],
      'pack.android': ['packages/appstein_engine/lib/src/packs/android/**'],
      'engine': ['packages/appstein_engine/**'],
    },
  }));

  test('the first matching tag wins', () {
    expect(matcher.tagFor('packages/appstein_engine/lib/src/packs/android/a.dart'),
        'pack.android');
    expect(matcher.tagFor('packages/appstein_engine/lib/src/host/b.dart'), 'engine');
    expect(matcher.tagFor('packages/appstein_engine/test/c_test.dart'), 'test');
  });

  test('files no glob matches get no tag', () {
    expect(matcher.tagFor('tool/x.dart'), isNull);
  });
}
```

`packages/appstein_lints/test/layer_imports_rule_test.dart`:
```dart
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer_testing/utilities/utilities.dart';
import 'package:appstein_lints/src/layer_imports/layer_imports_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(LayerImportsRuleTest);
  });
}

@reflectiveTest
class LayerImportsRuleTest extends AnalysisRuleTest {
  static const _layers = '''
appstein_lints:
  layers:
    ui: [lib/ui/**]
    domain: [lib/domain/**]
    data: [lib/data/**]
  allow:
    ui: [domain]
    domain: []
''';

  String get _ui => '$testPackageLibPath/ui/home.dart';

  void _options(String appsteinSection) => newAnalysisOptionsYamlFile(
      testPackageRootPath,
      '${analysisOptionsContent(rules: ['layer_imports'])}\n$appsteinSection');

  @override
  void setUp() {
    rule = LayerImportsRule();
    super.setUp();
    _options(_layers);
    newFile('$testPackageLibPath/domain/user.dart', 'class User {}');
    newFile('$testPackageLibPath/data/repo.dart', 'class Repo {}');
  }

  Future<void> test_allowedImport() async {
    newFile(_ui, "import '../domain/user.dart';\nUser? u;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_forbiddenRelativeImport() async {
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [
      lint(7, 19, messageContainsAll: ["'ui' layer can't import", 'lib/data/repo.dart']),
    ]);
  }

  Future<void> test_forbiddenPackageImport() async {
    newFile(_ui, "import 'package:test/data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 29)]);
  }

  Future<void> test_exportIsChecked() async {
    newFile(_ui, "export '../data/repo.dart';\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 19)]);
  }

  Future<void> test_sameLayerIsAllowed() async {
    newFile('$testPackageLibPath/ui/widgets.dart', 'class W {}');
    newFile(_ui, "import 'widgets.dart';\nW? w;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_layerWithoutAllowEntryIsUnrestricted() async {
    final data = '$testPackageLibPath/data/uses_ui.dart';
    newFile('$testPackageLibPath/ui/widgets.dart', 'class W {}');
    newFile(data, "import '../ui/widgets.dart';\nW? w;\n");
    await assertNoDiagnosticsInFile(data);
  }

  Future<void> test_untaggedFileIsIgnored() async {
    final main = '$testPackageLibPath/main.dart';
    newFile(main, "import 'data/repo.dart';\nRepo? r;\n");
    await assertNoDiagnosticsInFile(main);
  }

  Future<void> test_noAppsteinSectionMeansNoRule() async {
    _options('');
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_invalidConfigIsReported() async {
    _options('appstein_lints:\n  layers:\n    ui: [lib/ui/**]\n'
        '  allow:\n    ui: [nowhere]\n');
    newFile(_ui, 'class A {}\n');
    await assertDiagnosticsInFile(_ui, [
      lint(0, 0, messageContainsAll: ['invalid', '"nowhere"']),
    ]);
  }
}
```

Offsets: `import ` is 7 characters. `'../data/repo.dart'` is 19 characters, including the quotes. `'package:test/data/repo.dart'` is 29. The analyzer test package is named `test`.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/appstein_lints; fvm dart test`
Expected: FAIL, because the rule and matcher files don't exist.

- [ ] **Step 3: Write `layer_matcher.dart`**

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Gives files their layer tag using the globs in [LayerRules].
///
/// Paths are relative to the folder of the `analysis_options.yaml` that
/// declares the rules, and use `/` on every OS.
final class LayerMatcher {
  /// Creates a matcher for [rules].
  LayerMatcher(this.rules)
      : _globs = {
          for (final MapEntry(key: tag, value: patterns) in rules.layers.entries)
            tag: [for (final g in patterns) Glob(g, context: p.posix)],
        };

  /// The rules being matched.
  final LayerRules rules;

  final Map<String, List<Glob>> _globs;

  /// The first tag, in declaration order, whose globs match
  /// [relativePosixPath]. Null when none match.
  String? tagFor(String relativePosixPath) {
    for (final MapEntry(key: tag, value: globs) in _globs.entries) {
      if (globs.any((glob) => glob.matches(relativePosixPath))) return tag;
    }
    return null;
  }
}
```

- [ ] **Step 4: Write `layer_config.dart`**

```dart
import 'package:analyzer/file_system/file_system.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:yaml/yaml.dart';

/// The layer rules that apply to a file, and where they came from.
final class LayerConfig {
  /// Creates a config.
  const LayerConfig({
    required this.optionsPath,
    required this.rootPath,
    this.rules,
    this.error,
  });

  /// The `analysis_options.yaml` that declares the rules.
  final String optionsPath;

  /// Its folder. Globs are relative to it.
  final String rootPath;

  /// The rules, or null when the section is invalid.
  final LayerRules? rules;

  /// Why the section is invalid, when it is.
  final String? error;
}

/// Finds the layer rules for a file: the nearest `analysis_options.yaml`,
/// at or above the file's folder, that has a top-level `appstein_lints:`
/// section.
///
/// It reads through the analyzer's file system, so it sees unsaved editor
/// changes and works in tests. Parsed files are cached until they change.
final class LayerConfigFinder {
  final Map<String, (int, LayerConfig?)> _cache = {};

  /// The rules for [file], or null when no options file declares any.
  LayerConfig? find(File file) {
    var folder = file.parent;
    while (true) {
      final options = folder.getFile('analysis_options.yaml');
      if (options.exists) {
        final config = _read(options);
        if (config != null) return config;
      }
      if (folder.isRoot) return null;
      folder = folder.parent;
    }
  }

  LayerConfig? _read(File options) {
    final stamp = options.modificationStamp;
    final cached = _cache[options.path];
    if (cached != null && cached.$1 == stamp) return cached.$2;
    LayerConfig? config;
    try {
      final doc = loadYaml(options.readAsStringSync());
      if (doc is Map<Object?, Object?> && doc.containsKey('appstein_lints')) {
        try {
          config = LayerConfig(
            optionsPath: options.path,
            rootPath: options.parent.path,
            rules: LayerRules.fromJson(doc['appstein_lints']),
          );
        } on FormatException catch (error) {
          config = LayerConfig(
            optionsPath: options.path,
            rootPath: options.parent.path,
            error: error.message,
          );
        }
      }
    } on YamlException {
      // The analyzer already reports a broken analysis_options.yaml.
      config = null;
    }
    _cache[options.path] = (stamp, config);
    return config;
  }
}
```

- [ ] **Step 5: Write `layer_imports_rule.dart`**

```dart
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:path/path.dart' as p;

import 'layer_config.dart';
import 'layer_matcher.dart';

/// Enforces the layer boundaries declared in `appstein_lints:`
/// (spec §9.6). An import or export that crosses a forbidden boundary is
/// reported at its URI.
final class LayerImportsRule extends MultiAnalysisRule {
  /// Creates the rule.
  LayerImportsRule()
      : super(
          name: 'layer_imports',
          description: 'Code in one layer may only import the layers it is '
              'allowed to.',
        );

  /// Reported at an import or export that crosses a forbidden boundary.
  static const LintCode forbiddenImport = LintCode(
    'layer_imports',
    "The '{0}' layer can't import '{2}', which is in the '{1}' layer.",
    correctionMessage: "The '{0}' layer may import: {3}. Import an allowed "
        'layer instead, or move the code.',
    uniqueName: 'layer_imports_forbidden',
  );

  /// Reported once per file when the `appstein_lints:` section is invalid.
  static const LintCode invalidConfig = LintCode(
    'layer_imports',
    'The appstein_lints layer rules in {0} are invalid: {1}',
    correctionMessage: 'Fix the appstein_lints section of that file.',
    uniqueName: 'layer_imports_invalid_config',
  );

  final _finder = LayerConfigFinder();

  @override
  List<DiagnosticCode> get diagnosticCodes => [forbiddenImport, invalidConfig];

  @override
  void registerNodeProcessors(
      RuleVisitorRegistry registry, RuleContext context) {
    final file = (context.currentUnit ?? context.definingUnit).file;
    final config = _finder.find(file);
    if (config == null) return;
    final visitor = _Visitor(this, config, file);
    registry
      ..addCompilationUnit(this, visitor)
      ..addImportDirective(this, visitor)
      ..addExportDirective(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.config, this.file)
      : _matcher = config.rules == null ? null : LayerMatcher(config.rules!),
        _paths = file.provider.pathContext;

  final LayerImportsRule rule;
  final LayerConfig config;
  final File file;
  final LayerMatcher? _matcher;
  final p.Context _paths;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final error = config.error;
    if (error != null) {
      rule.reportAtOffset(0, 0,
          diagnosticCode: LayerImportsRule.invalidConfig,
          arguments: [config.optionsPath, error]);
    }
  }

  @override
  void visitImportDirective(ImportDirective node) =>
      _check(node, node.libraryImport?.importedLibrary);

  @override
  void visitExportDirective(ExportDirective node) =>
      _check(node, node.libraryExport?.exportedLibrary);

  void _check(NamespaceDirective node, LibraryElement? target) {
    final matcher = _matcher;
    final rules = config.rules;
    if (matcher == null || rules == null || target == null) return;
    final fromPath = _relative(file.path);
    final toPath = _relative(target.firstFragment.source.fullName);
    if (fromPath == null || toPath == null) return;
    final fromTag = matcher.tagFor(fromPath);
    final toTag = matcher.tagFor(toPath);
    if (fromTag == null || toTag == null || rules.mayImport(fromTag, toTag)) {
      return;
    }
    final allowed = [fromTag, ...?rules.allow[fromTag]].join(', ');
    rule.reportAtNode(node.uri,
        diagnosticCode: LayerImportsRule.forbiddenImport,
        arguments: [fromTag, toTag, toPath, allowed]);
  }

  /// [path] relative to the config folder, with `/` separators. Null when
  /// it is outside that folder (the SDK or the pub cache).
  String? _relative(String path) {
    if (!_paths.isWithin(config.rootPath, path)) return null;
    return _paths.split(_paths.relative(path, from: config.rootPath)).join('/');
  }
}
```

- [ ] **Step 6: Write the plugin entry point**

`lib/src/appstein_lints_plugin.dart`:
```dart
import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'layer_imports/layer_imports_rule.dart';

/// Registers Appstein's lint rules with the Dart analysis server.
///
/// Plugin lint rules are off by default. A project turns them on under
/// `plugins: appstein_lints: diagnostics:` in `analysis_options.yaml`.
final class AppsteinLintsPlugin extends Plugin {
  @override
  String get name => 'appstein_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerLintRule(LayerImportsRule());
  }
}
```

Replace `lib/main.dart` with:
```dart
import 'src/appstein_lints_plugin.dart';

/// The plugin the Dart analysis server loads (see `plugins:` in
/// `analysis_options.yaml`). The analysis server requires this exact name.
final plugin = AppsteinLintsPlugin();
```

- [ ] **Step 7: Run the tests and the analyzer**

Run: `cd packages/appstein_lints; fvm dart test; cd ../..; fvm dart analyze --fatal-infos`
Expected: `All tests passed!` and no issues.
- If `lint(...)` doesn't match because the two codes' names differ in how `ExpectedLint` compares them, pass `name: 'layer_imports'` explicitly.
- If a test fails with "unused import" noise, check that each fixture uses its imported type.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add packages/appstein_lints
git commit -m "feat(lints): add the layer_imports analyzer rule"
```

---

### Task 11: Enforce our own package boundaries with `layer_imports`

**Why:** spec §4 principle 8 is "use our own product on our own repo". Pubspec dependencies already stop `protocol` from importing `engine`. The lint adds the rules that pubspec can't express:
- the engine core never imports a pack;
- packs never import each other.

The pack folders don't exist yet; declaring their tags now means the rule is already in place when slice 1b adds them.

**Files:**
- Modify: `analysis_options.yaml`

- [ ] **Step 1: Add the plugin and our boundary rules**

Append to the root `analysis_options.yaml`:
```yaml

plugins:
  appstein_lints:
    path: packages/appstein_lints
    diagnostics:
      layer_imports: true

# Appstein's own package boundaries (spec §5.1), enforced by layer_imports.
# The first matching tag wins, so tests and packs come before the packages
# that contain them. Tags without an allow entry (tests) are unrestricted.
appstein_lints:
  layers:
    test: [packages/*/test/**]
    pack.official_mvvm: [packages/appstein_engine/lib/src/packs/official_mvvm/**]
    pack.android: [packages/appstein_engine/lib/src/packs/android/**]
    pack.ios: [packages/appstein_engine/lib/src/packs/ios/**]
    protocol: [packages/appstein_protocol/**]
    engine: [packages/appstein_engine/**]
    cli: [packages/appstein_cli/**]
    lints: [packages/appstein_lints/**]
  allow:
    protocol: []
    engine: [protocol]
    pack.official_mvvm: [engine, protocol]
    pack.android: [engine, protocol]
    pack.ios: [engine, protocol]
    cli: [engine, protocol, pack.official_mvvm, pack.android, pack.ios]
    lints: [protocol]
```
The CLI may import packs because it is where packs get registered with the engine: it is the composition root.

- [ ] **Step 2: Run the analyzer on the whole workspace**

Run: `fvm dart analyze --fatal-infos`
Expected: `No issues found!`. The first run is slower, because the analysis server compiles the plugin.

- [ ] **Step 3: Prove the rule catches a real violation**

Create two throwaway files:

`packages/appstein_engine/lib/src/packs/official_mvvm/probe.dart`:
```dart
/// Throwaway probe for Task 11. Delete after the check.
class Probe {}
```

`packages/appstein_engine/lib/src/host/probe_user.dart`:
```dart
import '../packs/official_mvvm/probe.dart';

/// Throwaway probe for Task 11. Delete after the check.
Probe? probe;
```

Run: `fvm dart analyze --fatal-infos`
Expected: exactly one issue, `layer_imports`, at `probe_user.dart:1:8`, saying "The 'engine' layer can't import 'packages/appstein_engine/lib/src/packs/official_mvvm/probe.dart', which is in the 'pack.official_mvvm' layer."

Then delete both files and the empty `packs` folder, and run `fvm dart analyze --fatal-infos` again. Expected: `No issues found!`.

- [ ] **Step 4: Commit (after the owner approves)**

```powershell
git add analysis_options.yaml
git commit -m "chore: enforce Appstein's own package boundaries with layer_imports"
```

---

### Task 12: AOT build and the start-up budget

**Why:** hooks run `appstein` after every agent edit, so start-up time is paid constantly. Spec §15 sets a 200 ms budget for the compiled executable.

**Files:**
- Create: `tool/startup_check.dart`

- [ ] **Step 1: Write the start-up check**

`tool/startup_check.dart`:
```dart
import 'dart:io';

/// Runs a compiled `appstein --version` several times and fails when the
/// median start-up exceeds the 200 ms budget (spec §15).
///
/// Usage: fvm dart run tool/startup_check.dart <path to compiled appstein>
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/startup_check.dart <path to appstein>');
    exitCode = 2;
    return;
  }
  const runs = 7;
  const budgetMs = 200;
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    final result = await Process.run(arguments.single, ['--version']);
    watch.stop();
    if (result.exitCode != 0) {
      stderr.writeln('appstein --version failed: ${result.stderr}');
      exitCode = 1;
      return;
    }
    times.add(watch.elapsedMilliseconds);
  }
  times.sort();
  final median = times[runs ~/ 2];
  stdout.writeln('appstein --version start-up: median $median ms over $runs '
      'runs (budget $budgetMs ms). All runs: $times');
  if (median > budgetMs) exitCode = 1;
}
```

- [ ] **Step 2: Compile and check it**

```powershell
New-Item -ItemType Directory -Force build | Out-Null
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe
./build/appstein.exe --version
fvm dart run tool/startup_check.dart build/appstein.exe
```
Expected: the version text, then a median under 200 ms. Write the measured median into the Measurements section at the end of this plan.

- [ ] **Step 3: Commit (after the owner approves)**

```powershell
git add tool/startup_check.dart
git commit -m "chore: add the AOT start-up budget check"
```

---

### Task 13: Measure the fast-verify budget (spec §9.1, §22 #21)

**Why:** the spec requires every fast check to finish in under 5 s. The biggest cost is a *cold* `dart analyze` with our analyzer plugin loaded. This task measures that on a realistic app, then records a decision:
- keep running cold analysis in the hook (1d); or
- plan the fallback, which is warm analysis inside the long-running `appstein mcp` process.

**Decision rule:** if the median single-file analyze with the plugin is **≤ 3.0 s**, both on the Windows development machine and on CI Linux, keep cold analysis. That leaves about 2 s for the other fast checks. Otherwise, slice 1d plans warm analysis.

**Files:**
- Create: `tool/measure_analyze.dart`

- [ ] **Step 1: Write the measurement script**

`tool/measure_analyze.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// Measures `dart analyze` with and without the appstein_lints plugin on a
/// fresh Flutter app with about 200 generated files (spec §9.1, §15).
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_analyze.dart --flutter <path to flutter(.bat)>
/// Prints a Markdown table to paste into the slice 1a plan.
Future<void> main(List<String> arguments) async {
  final flutterIndex = arguments.indexOf('--flutter');
  final flutter = flutterIndex >= 0 && flutterIndex + 1 < arguments.length
      ? arguments[flutterIndex + 1]
      : 'flutter';
  final dart = Platform.resolvedExecutable;
  final repo = Directory.current.path;
  final work = Directory.systemTemp.createTempSync('appstein measure ');
  final app = p.join(work.path, 'measure app');
  try {
    await _run(flutter, ['create', '--project-name', 'measure_app',
        '--platforms', 'android,ios', app], work.path);
    _generateFiles(app, features: 50);
    final withPlugin = '''
include: package:flutter_lints/flutter.yaml

plugins:
  appstein_lints:
    path: ${p.join(repo, 'packages', 'appstein_lints').replaceAll(r'\', '/')}
    diagnostics:
      layer_imports: true

appstein_lints:
  layers:
    ui: [lib/ui/**]
    data: [lib/data/**]
    domain: [lib/domain/**]
  allow:
    ui: [data, domain]
    data: [domain]
    domain: []
''';
    const withoutPlugin = 'include: package:flutter_lints/flutter.yaml\n';
    final options = File(p.join(app, 'analysis_options.yaml'));
    final oneFile = p.join('lib', 'ui', 'feature_0', 'feature_0_screen.dart');

    options.writeAsStringSync(withoutPlugin);
    final baseline = await _median(() => _time(dart, ['analyze', oneFile], app));

    options.writeAsStringSync(withPlugin);
    final firstRun = await _time(dart, ['analyze'], app); // compiles the plugin
    final wholeProject = await _median(() => _time(dart, ['analyze'], app));
    final single = await _median(() => _time(dart, ['analyze', oneFile], app));

    stdout.writeln('''
| Measurement (${Platform.operatingSystem}) | Time |
|---|---|
| Single file, no plugin (median of 3) | ${baseline} ms |
| Whole project, first run with plugin (includes plugin build) | ${firstRun} ms |
| Whole project with plugin (median of 3) | ${wholeProject} ms |
| **Single file with plugin (median of 3)** | **${single} ms** |
''');
  } finally {
    work.deleteSync(recursive: true);
  }
}

void _generateFiles(String app, {required int features}) {
  for (var i = 0; i < features; i++) {
    void write(String relative, String content) {
      File(p.join(app, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    write('lib/domain/models/model_$i.dart', 'class Model$i {\n'
        '  const Model$i(this.id);\n  final int id;\n}\n');
    write('lib/data/repositories/repo_$i.dart',
        "import '../../domain/models/model_$i.dart';\n\n"
        'class Repo$i {\n  Model$i load() => const Model$i($i);\n}\n');
    write('lib/ui/feature_$i/feature_${i}_view_model.dart',
        "import 'package:flutter/foundation.dart';\n"
        "import '../../data/repositories/repo_$i.dart';\n\n"
        'class Feature${i}ViewModel extends ChangeNotifier {\n'
        '  Feature${i}ViewModel(this.repo);\n  final Repo$i repo;\n}\n');
    write('lib/ui/feature_$i/feature_${i}_screen.dart',
        "import 'package:flutter/material.dart';\n"
        "import 'feature_${i}_view_model.dart';\n\n"
        'class Feature${i}Screen extends StatelessWidget {\n'
        '  const Feature${i}Screen({super.key, required this.viewModel});\n'
        '  final Feature${i}ViewModel viewModel;\n'
        '  @override\n  Widget build(BuildContext context) => const Placeholder();\n}\n');
  }
}

Future<int> _median(Future<int> Function() measure) async {
  final times = [await measure(), await measure(), await measure()]..sort();
  return times[1];
}

Future<int> _time(String executable, List<String> args, String cwd) async {
  final watch = Stopwatch()..start();
  await _run(executable, args, cwd, allowFailure: true);
  return watch.elapsedMilliseconds;
}

Future<void> _run(String executable, List<String> args, String cwd,
    {bool allowFailure = false}) async {
  final result = await Process.run(executable, args,
      workingDirectory: cwd, runInShell: Platform.isWindows);
  if (result.exitCode != 0 && !allowFailure) {
    throw ProcessException(executable, args,
        '${result.stdout}\n${result.stderr}', result.exitCode);
  }
}
```
The 50 features × 4 files, plus the template, make about 200 Dart files, which is the spec §15 "200-file app".

- [ ] **Step 2: Run it on the development machine**

```powershell
fvm dart run tool/measure_analyze.dart --flutter C:\Users\<you>\fvm\versions\3.47.5\bin\flutter.bat
```
Expected: a table. Paste it into the Measurements section at the end of this plan, then apply the decision rule and write the decision there too.

- [ ] **Step 3: Commit (after the owner approves)**

```powershell
git add tool/measure_analyze.dart docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md
git commit -m "chore: measure cold analysis with the plugin and record the fast-verify decision"
```

---

### Task 14: Developer guide skeleton and the guide checker (spec §19.6)

**Why:** the guide is for people working on Appstein without an agent. It describes only code that exists, which is why it is written now, for what 1a built. The checker keeps it honest:
- relative links must resolve;
- repo paths in backticks must exist;
- Dart code blocks are refused until slice 1f can analyze them.

**Files:**
- Create: `tool/src/guide_checker.dart`, `tool/check_guide.dart`, `test/guide_checker_test.dart`
- Create: `docs/guide/README.md`, `docs/guide/architecture.md`, `docs/guide/debugging.md`
- Modify: `AGENTS.md`, `README.md`

**Interfaces:**
- Produces: `GuideProblem{file, line, message}`, `List<GuideProblem> checkMarkdown(String repoRoot, String relativePath)` and `List<String> guideFiles(String repoRoot)`.

- [ ] **Step 1: Write the failing test**

`test/guide_checker_test.dart` (at the repo root):
```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/guide_checker.dart';

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('appstein guide tëst ');
    addTearDown(() => repo.deleteSync(recursive: true));
    Directory(p.join(repo.path, 'docs', 'guide')).createSync(recursive: true);
    Directory(p.join(repo.path, 'packages', 'appstein_cli', 'bin'))
        .createSync(recursive: true);
    File(p.join(repo.path, 'packages', 'appstein_cli', 'README.md'))
        .writeAsStringSync('# cli\n');
  });

  List<String> check(String markdown) {
    File(p.join(repo.path, 'docs', 'guide', 'page.md')).writeAsStringSync(markdown);
    return [
      for (final problem in checkMarkdown(repo.path, p.join('docs', 'guide', 'page.md')))
        '${problem.line}: ${problem.message}',
    ];
  }

  test('accepts good links, existing paths and non-Dart code blocks', () {
    expect(
      check('See [the CLI](../../packages/appstein_cli/README.md#top) and '
          '`packages/appstein_cli/bin/` and [web](https://dart.dev).\n'
          '```powershell\nfvm dart test\n```\n'),
      isEmpty,
    );
  });

  test('reports broken links and missing paths with line numbers', () {
    expect(check('# Title\n[x](missing.md)\n`packages/nope/lib/`\n'), [
      '2: Broken link: missing.md',
      '3: Path does not exist: packages/nope/lib/',
    ]);
  });

  test('refuses Dart code blocks until snippet analysis exists', () {
    expect(check('```dart\nvoid main() {}\n```\n').single,
        contains('Dart code blocks are not analyzed yet'));
  });

  test('ignores links and paths inside code blocks', () {
    expect(check('```text\n[x](missing.md) `packages/nope/`\n```\n'), isEmpty);
  });

  test('covers the guide and every package README', () {
    File(p.join(repo.path, 'docs', 'guide', 'page.md')).writeAsStringSync('');
    expect(guideFiles(repo.path), [
      p.join('docs', 'guide', 'page.md'),
      p.join('packages', 'appstein_cli', 'README.md'),
    ]);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm dart test test/guide_checker_test.dart` (from the repo root)
Expected: FAIL, because `tool/src/guide_checker.dart` doesn't exist.

- [ ] **Step 3: Write the checker**

`tool/src/guide_checker.dart`:
```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// A problem found in a Markdown file.
final class GuideProblem {
  /// Creates a problem at [line] of [file].
  const GuideProblem(this.file, this.line, this.message);

  /// The file, relative to the repo root.
  final String file;

  /// The 1-based line.
  final int line;

  /// What is wrong.
  final String message;

  @override
  String toString() => '$file:$line: $message';
}

final _link = RegExp(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
final _codeSpan = RegExp(r'`([^`\s]+)`');
final _repoPath = RegExp(r'^(packages|docs|tool|\.github)/');

/// Checks one Markdown file of the developer guide (spec §19.6):
/// - relative links must resolve;
/// - repo paths in backticks must exist;
/// - Dart code blocks are refused until slice 1f adds snippet analysis.
List<GuideProblem> checkMarkdown(String repoRoot, String relativePath) {
  final file = File(p.join(repoRoot, relativePath));
  final problems = <GuideProblem>[];
  var inFence = false;
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      if (!inFence && trimmed.substring(3).trim().toLowerCase() == 'dart') {
        problems.add(GuideProblem(relativePath, i + 1,
            'Dart code blocks are not analyzed yet (slice 1f adds that). '
            'Link to real code in the repo instead.'));
      }
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    for (final match in _link.allMatches(line)) {
      final target = match.group(1)!;
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:') ||
          target.startsWith('#')) {
        continue;
      }
      final path = Uri.decodeFull(target.split('#').first);
      final resolved = p.normalize(p.join(p.dirname(file.path), path));
      if (FileSystemEntity.typeSync(resolved) == FileSystemEntityType.notFound) {
        problems.add(GuideProblem(relativePath, i + 1, 'Broken link: $target'));
      }
    }
    for (final match in _codeSpan.allMatches(line)) {
      final text = match.group(1)!;
      if (!_repoPath.hasMatch(text) || text.contains('*') || text.contains('<')) {
        continue;
      }
      final resolved = p.join(repoRoot,
          text.endsWith('/') ? text.substring(0, text.length - 1) : text);
      if (FileSystemEntity.typeSync(resolved) == FileSystemEntityType.notFound) {
        problems.add(
            GuideProblem(relativePath, i + 1, 'Path does not exist: $text'));
      }
    }
  }
  return problems;
}

/// The files the guide check covers: every Markdown file under
/// `docs/guide/`, plus each package README. Paths are relative to
/// [repoRoot] and sorted.
List<String> guideFiles(String repoRoot) {
  final files = <String>[];
  final guide = Directory(p.join(repoRoot, 'docs', 'guide'));
  if (guide.existsSync()) {
    for (final entry in guide.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.md')) {
        files.add(p.relative(entry.path, from: repoRoot));
      }
    }
  }
  final packages = Directory(p.join(repoRoot, 'packages'));
  if (packages.existsSync()) {
    for (final entry in packages.listSync().whereType<Directory>()) {
      final readme = File(p.join(entry.path, 'README.md'));
      if (readme.existsSync()) files.add(p.relative(readme.path, from: repoRoot));
    }
  }
  return files..sort();
}
```

`tool/check_guide.dart`:
```dart
import 'dart:io';

import 'src/guide_checker.dart';

/// Checks the developer guide and package READMEs. Run from the repo root:
///   fvm dart run tool/check_guide.dart
void main() {
  final root = Directory.current.path;
  final files = guideFiles(root);
  final problems = [for (final file in files) ...checkMarkdown(root, file)];
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  stdout.writeln(problems.isEmpty
      ? 'Guide check passed (${files.length} files).'
      : '${problems.length} problem(s) found.');
  if (problems.isNotEmpty) exitCode = 1;
}
```

- [ ] **Step 4: Run the test**

Run: `fvm dart test test/guide_checker_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Write the guide pages**

`docs/guide/README.md`:
````markdown
# Appstein developer guide: start here

This guide is for people working on Appstein's code without an agent. It explains how the code works **now**, and each page is written in the slice that builds what it describes. For *what* was decided and *why*, read the [design spec](../superpowers/specs/2026-09-29-appstein-design.md). This guide links to it instead of repeating it.

## Set up

1. Install [FVM](https://fvm.app). The repo pins Flutter 3.47.5 in `.fvmrc`.
2. In the repo folder, run:
   ```powershell
   fvm install
   fvm dart pub get
   ```
3. Always use `fvm dart` and `fvm flutter`. A plain `dart` on your PATH may be a different, older SDK. `appstein doctor` warns you when that is the case.

On Windows, everything works in PowerShell, including paths with spaces.

## A tour of the repo

| Folder | What it holds |
|---|---|
| `packages/appstein_protocol/` | Shared data models ([README](../../packages/appstein_protocol/README.md)) |
| `packages/appstein_engine/` | All logic: host access, config, SDK detection, doctor ([README](../../packages/appstein_engine/README.md)) |
| `packages/appstein_cli/` | The `appstein` command, a thin layer over the engine ([README](../../packages/appstein_cli/README.md)) |
| `packages/appstein_lints/` | The analyzer plugin with our lint rules ([README](../../packages/appstein_lints/README.md)) |
| `tool/` | Repo scripts: start-up check, analyze measurement, guide check |
| `docs/` | Spec, plans, research and this guide |

The four packages form a [pub workspace](https://dart.dev/tools/pub/workspaces): one `pubspec.lock` and one `analysis_options.yaml` at the root. The packages may only depend on each other in one direction (spec §5.1), and the `layer_imports` rule enforces that. See [architecture](architecture.md).

## Build and run the CLI from source

```powershell
fvm dart run packages/appstein_cli/bin/appstein.dart --version
fvm dart run packages/appstein_cli/bin/appstein.dart doctor
```

To compile the fast, standalone binary that hooks use:

```powershell
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe
fvm dart run tool/startup_check.dart build/appstein.exe
```

## Run the tests

Tests live in each package. Run them from that package's folder:

```powershell
cd packages/appstein_engine
fvm dart test                      # unit tests
fvm dart test --run-skipped --tags integration   # checks your real machine
```

The guide checker and its test run from the repo root:

```powershell
fvm dart test test/guide_checker_test.dart
fvm dart run tool/check_guide.dart
```

Before you commit, run `fvm dart format .` and `fvm dart analyze --fatal-infos` from the repo root.
````

`docs/guide/architecture.md`:
````markdown
# How the code fits together

This page covers what exists after slice 1a. Packs, knowledge, the verifier and the MCP server join it in later slices.

## The four packages

```text
appstein_cli ──► appstein_engine ──► appstein_protocol
                                          ▲
appstein_lints ───────────────────────────┘
```

- **protocol** holds data only: `SdkInfo`, `AppsteinConfig`, `LayerRules` and `Severity`. It has no logic that touches the machine.
- **engine** holds all behaviour. It reaches the machine only through two small types in `packages/appstein_engine/lib/src/host/`:
  - `HostEnvironment` for environment variables, the PATH and the OS;
  - `ProcessRunner` for running tools.

  Tests swap them for fakes, which is why engine tests never depend on what is installed.
- **cli** parses arguments, calls the engine and prints. `runAppstein()` returns an exit code instead of exiting, so tests run the whole CLI in-process.
- **lints** runs inside the Dart analyzer, so its rules appear in every IDE and agent.

## How `appstein doctor` works

1. `bin/appstein.dart` calls `runAppstein()`, in `packages/appstein_cli/lib/src/runner.dart`.
2. The `doctor` command resolves the project: `--project`, or the nearest folder with a `pubspec.yaml`.
3. `Doctor.run()` detects the Flutter SDK **once**. The order is the FVM pin, then FLUTTER_ROOT, then PATH. The code is in `packages/appstein_engine/lib/src/sdk/`.
4. Every check in `packages/appstein_engine/lib/src/doctor/checks/` runs in parallel with that shared context. Each returns a `CheckResult`: ok, info, warning, error or skipped, with a fix hint.
5. The CLI prints the report and exits `1` if any check found an error, `0` otherwise, and `3` if Appstein itself failed (spec §9.5).

To add a check, write a class that implements `DoctorCheck`, test it with the fakes in `packages/appstein_engine/test/support/`, and add it to `defaultDoctorChecks()`.

## How `layer_imports` finds its rules

The analyzer only lets plugins have on/off switches, so the rules live in a **top-level** `appstein_lints:` section of `analysis_options.yaml`. See `LayerConfigFinder` in `packages/appstein_lints/lib/src/layer_imports/`: it walks up from the analyzed file to the nearest options file that has that section. Our own repo's boundaries are declared at the bottom of the root `analysis_options.yaml`.
````

`docs/guide/debugging.md`:
````markdown
# Debugging

## `appstein` exits with code 3

Code 3 means Appstein itself failed: a bad option, an invalid `appstein.yaml`, or a crash. The error output says which. Run `appstein doctor` first, because most failures are environment problems it explains.

## The analyzer plugin

- `print` does nothing inside a plugin, because it runs in a separate isolate in the analysis server. To see what a rule does, write a test in `packages/appstein_lints/test/` instead.
- After changing plugin code, restart the analysis server. In VS Code, run "Dart: Restart Analysis Server". On the command line, each `fvm dart analyze` starts fresh.
- The first analysis after a change is slower, because the server recompiles the plugin.

## Windows paths

Engine tests create temporary folders with a space and a non-ASCII character in the name, because paths like `C:\Users\Jöhn Doe\my app` must work. If a test fails only on Windows, suspect quoting: `.bat` and `.cmd` files run through `cmd.exe`, as done in `packages/appstein_engine/lib/src/host/process_runner.dart`.
````

- [ ] **Step 6: Update `AGENTS.md` and `README.md`**

In `AGENTS.md`:
- Replace the **Current phase** line with:
  `**Current phase:** M1 slice 1a is being implemented (plan: docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md).`
- Replace the Flutter SDK gotcha with:
  ```markdown
  - **Flutter SDK:** the repo pins Flutter 3.47.5 in `.fvmrc`. Run every command through FVM (`fvm dart …`, `fvm flutter …`). The `dart` on your PATH may be an older SDK.
  ```
- Add under **Source of truth**:
  ```markdown
  - **Developer guide:** `docs/guide/` explains how the code works now, for humans. Update the pages a change affects, and run `fvm dart run tool/check_guide.dart`.
  ```

In `README.md`, replace the status line with:
```markdown
> **Status:** pre-alpha. Milestone 1, slice 1a (workspace, CLI, SDK detection, `doctor`) is in progress. Start with the [developer guide](docs/guide/README.md).
```

- [ ] **Step 7: Run the guide check**

Run: `fvm dart run tool/check_guide.dart`
Expected: `Guide check passed (7 files).` That's three guide pages plus four package READMEs.

- [ ] **Step 8: Commit (after the owner approves)**

```powershell
git add tool test docs/guide AGENTS.md README.md
git commit -m "docs: add the developer guide skeleton and the guide checker"
```

---

### Task 15: CI on Windows, macOS and Linux, including the real-machine doctor test and the minimum SDK

**Why:** the 1a exit criteria are "doctor correct on Windows, macOS and Linux CI; CI green; minimum supported Flutter version confirmed". Three pieces of this task produce that evidence:
- a real-environment doctor test, which compares doctor's Flutter version with `flutter --version --machine`;
- a job on Flutter 3.44.x, which proves the minimum, including the analyzer plugin;
- the start-up budget check, run on all three OSes.

**Files:**
- Create: `packages/appstein_engine/test/integration/doctor_real_environment_test.dart`, `packages/appstein_engine/dart_test.yaml`
- Create: `.github/workflows/ci.yml`
- Modify: `pubspec.yaml` (root; add `dependency_validator`), `docs/guide/README.md` (a CI section)

- [ ] **Step 1: Write the real-environment test**

`packages/appstein_engine/dart_test.yaml`:
```yaml
tags:
  integration:
    # Uses the real machine (Flutter, PATH, JDK), so a plain `dart test`
    # skips it. CI runs it separately.
    skip: "Uses the real machine. Run with --run-skipped --tags integration."
```

`packages/appstein_engine/test/integration/doctor_real_environment_test.dart`:
```dart
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('doctor reports the same Flutter version as flutter itself', () async {
    final environment = HostEnvironment.current();
    final flutter = findExecutable('flutter', environment);
    if (flutter == null) {
      markTestSkipped('flutter is not on PATH');
      return;
    }
    const runner = SystemProcessRunner();
    final machine = await runner.run(flutter, ['--version', '--machine'],
        timeout: const Duration(minutes: 3));
    expect(machine.ok, isTrue, reason: machine.stderr);
    final json = jsonDecode(machine.stdout.substring(machine.stdout.indexOf('{')))
        as Map<String, Object?>;

    final report = await Doctor(environment: environment, runner: runner).run();
    final flutterEntry =
        report.entries.singleWhere((e) => e.check.id == 'doctor.flutter');
    expect(flutterEntry.result.summary, contains(json['frameworkVersion']));
    for (final entry in report.entries) {
      expect(entry.result.summary, isNot(startsWith('The check itself failed')),
          reason: entry.check.id);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
```

Run it locally: `cd packages/appstein_engine; fvm dart test --run-skipped --tags integration`
Expected: PASS. It uses the `flutter` on your PATH, whichever version that is. `doctor` runs outside a project here, so it also uses PATH. A plain `fvm dart test` reports the test as skipped.

- [ ] **Step 2: Add `dependency_validator`**

Run: `fvm dart pub add --dev dependency_validator --directory .` then `fvm dart run dependency_validator`
- Expected: it reports on all four packages and the root, with no problems.
- If it reports only the root, run it in each package folder in CI instead. Add it as a dev dependency of each package: `fvm dart pub add --dev dependency_validator --directory packages/<name>`.
- If it flags a real unused or missing dependency, fix the pubspec.
- If it flags a false positive (for example `lints`, which is used only by `analysis_options.yaml`), add a `dart_dependency_validator.yaml` at the root with `ignore: [lints]`, and a comment saying why.

- [ ] **Step 3: Write the workflow**

`.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

env:
  FLUTTER_STABLE: "3.47.5"   # keep in step with .fvmrc
  FLUTTER_MIN: "3.44.x"      # spec §22 #14: proposed minimum

jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_STABLE }}
          channel: stable
          cache: true
      - run: dart pub get --enforce-lockfile
      - run: dart format --output=none --set-exit-if-changed .
      - run: dart analyze --fatal-infos
      - run: dart run dependency_validator

  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_STABLE }}
          channel: stable
          cache: true
      - run: dart pub get --enforce-lockfile
      - name: Unit tests
        shell: bash
        run: |
          dart test test
          for pkg in packages/*/; do (cd "$pkg" && dart test) || exit 1; done
      - name: Doctor against this real machine
        shell: bash
        working-directory: packages/appstein_engine
        run: dart test --run-skipped --tags integration

  build:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_STABLE }}
          channel: stable
          cache: true
      - run: dart pub get --enforce-lockfile
      - name: Compile appstein
        shell: bash
        run: |
          mkdir -p build
          dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein${{ runner.os == 'Windows' && '.exe' || '' }}
      - name: Start-up budget (spec §15)
        shell: bash
        run: dart run tool/startup_check.dart build/appstein${{ runner.os == 'Windows' && '.exe' || '' }}
      - name: Run doctor (report only)
        shell: bash
        run: ./build/appstein${{ runner.os == 'Windows' && '.exe' || '' }} doctor || true
      - uses: actions/upload-artifact@v4
        with:
          name: appstein-${{ runner.os }}
          path: build/appstein*

  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_STABLE }}
          channel: stable
          cache: true
      - run: dart pub get --enforce-lockfile
      - name: API docs build without warnings
        shell: bash
        run: for pkg in packages/*/; do (cd "$pkg" && dart doc --dry-run) || exit 1; done
      - name: Developer guide check
        run: dart run tool/check_guide.dart

  min-sdk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_MIN }}
          channel: stable
      - run: flutter --version
      # No --enforce-lockfile: an older SDK may need older versions of some
      # dependencies, and finding out is the point of this job.
      - run: dart pub get
      - name: Analyze, which also loads our analyzer plugin on the old SDK
        run: dart analyze --fatal-infos
      - name: Unit tests
        shell: bash
        run: for pkg in packages/*/; do (cd "$pkg" && dart test) || exit 1; done

  measure:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_STABLE }}
          channel: stable
          cache: true
      - run: dart pub get --enforce-lockfile
      - name: Measure cold analysis with the plugin (spec §9.1)
        shell: bash
        run: dart run tool/measure_analyze.dart --flutter "$(command -v flutter)" >> "$GITHUB_STEP_SUMMARY"
```

`dart doc` fails on errors, but by default not on warnings. To make broken references fail, add `packages/<name>/dartdoc_options.yaml` to each package:
```yaml
dartdoc:
  errors:
    - unresolved-doc-reference
    - broken-link
```

- [ ] **Step 4: Check the workflow locally, as far as possible**

```powershell
fvm dart format --output=none --set-exit-if-changed .
fvm dart analyze --fatal-infos
foreach ($pkg in Get-ChildItem packages -Directory) { Push-Location $pkg.FullName; fvm dart doc --dry-run; Pop-Location }
fvm dart run tool/check_guide.dart
```
Expected: every command succeeds.

- [ ] **Step 5: Add a CI section to the guide**

Append to `docs/guide/README.md`:
```markdown
## CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | What it proves |
|---|---|
| `analyze` | Formatting, analyzer (including `layer_imports`), dependency hygiene |
| `test` | Unit tests on Windows, macOS and Linux, plus `doctor` against each real runner |
| `build` | The AOT binary on all three OSes, under the 200 ms start-up budget |
| `docs` | API docs build cleanly; this guide's links and paths are valid |
| `min-sdk` | Everything still works on the oldest supported Flutter (3.44) |
| `measure` | Cold-analysis timings for the fast-verify budget, in the job summary |
```

- [ ] **Step 6: Commit, then push (with the owner's approval), and read CI**

```powershell
git add .github pubspec.yaml pubspec.lock packages docs/guide
git commit -m "ci: test, build, document and measure on Windows, macOS and Linux"
```
Pushing is required to run CI. Ask the owner explicitly: **"May I push `slice-1a` to origin to run CI?"** Only push after a clear yes: `git push -u origin slice-1a`. Then run `gh run watch`, and read every job.
- **If `min-sdk` fails** because a dependency needs a newer Dart than 3.12: record exactly which package and version in the Measurements section, and stop to ask the owner. The choice is to raise the minimum or to pin an older dependency. That is the owner's decision (spec §22 #14).
- **If `build` fails the 200 ms budget on a CI OS but passes locally:** record the numbers. Treat it as a finding for the owner rather than raising the budget silently.

---

### Task 16: Verify the slice and close it with the owner

**Files:**
- Modify: this plan (the Measurements section), and the spec (only with the owner's approval)

- [ ] **Step 1: Run the full local verification**

Use superpowers:verification-before-completion. From the repo root:
```powershell
fvm dart format --output=none --set-exit-if-changed .
fvm dart analyze --fatal-infos
fvm dart test test
foreach ($pkg in Get-ChildItem packages -Directory) { Push-Location $pkg.FullName; fvm dart test; Pop-Location }
Push-Location packages/appstein_engine; fvm dart test --run-skipped --tags integration; Pop-Location
fvm dart run tool/check_guide.dart
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe
fvm dart run tool/startup_check.dart build/appstein.exe
./build/appstein.exe doctor
```
Expected: everything passes. `doctor` prints the report described in Task 9, Step 7.

- [ ] **Step 2: Check the 1a exit criteria (spec §18)**

| Criterion | Evidence |
|---|---|
| `doctor` correct on Windows, macOS and Linux CI | The `test` job's "Doctor against this real machine" step is green on all three OSes |
| CI green | Every job in the CI run for `slice-1a` |
| Minimum supported Flutter version confirmed | The `min-sdk` job is green on Flutter 3.44.x |
| The guide's start page builds and runs the CLI from source | Follow `docs/guide/README.md` literally, in a fresh PowerShell window |
| Fast verify < 5 s measured, and the fallback decided | The Measurements section below |
| Start-up < 200 ms | The `build` job output and the Measurements section |

- [ ] **Step 3: Propose the spec updates to the owner**

When the evidence is in, propose these edits (don't make them without approval):
- §22 #14: "Proposed **Flutter 3.44+** … Confirm in slice 1a" becomes "**Flutter 3.44+**, confirmed in slice 1a by CI (`min-sdk` job)", or whatever the job showed.
- §22 #21 and §9.1: record the measured single-file time and the decision, either "cold analysis kept" or "warm analysis in the MCP process planned for 1d".
- If the visual page mentions either item (its "Still to prove" list does), update it to match and re-check it against the spec.

- [ ] **Step 4: Owner review, then finish the branch**

Show the owner:
- the `doctor` output from their machine, including the real JDK problem it found;
- the measurements;
- the CI run.

After their review, use superpowers:finishing-a-development-branch to decide how `slice-1a` merges into `main`. Commits need their approval; pushes need an explicit "push".

---

## Measurements (filled in during Tasks 12, 13 and 15)

| What | Where | Result |
|---|---|---|
| AOT `appstein --version` start-up, median of 7 | Windows development machine | **34 ms** (runs: 32, 33, 34, 34, 37, 47, 56 ms), 2026-09-30 |
| AOT start-up, median of 7 | CI Linux / Windows / macOS | _Task 15_ |
| Single-file `dart analyze`, no plugin | Windows development machine | _Task 13_ |
| Single-file `dart analyze` with the plugin | Windows development machine | _Task 13_ |
| Single-file `dart analyze` with the plugin | CI Linux / Windows | _Task 15_ |
| Whole ~200-file app with the plugin | Windows development machine | _Task 13_ |
| Oldest Flutter that passes `min-sdk` | CI | _Task 15_ |

**Fast-verify decision (spec §9.1):** _written after Task 13, using the rule in Task 13._

**Notes from execution:** _anything that differed from this plan, and why._

