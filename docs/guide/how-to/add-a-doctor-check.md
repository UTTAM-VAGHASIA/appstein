<!-- covers: packages/appstein_engine/lib/src/doctor/doctor_check.dart -->

# How to: add a doctor check

These steps add one check to `appstein doctor`. Read [doctor](../doctor.md) first for how a run works. The existing checks in `packages/appstein_engine/lib/src/doctor/checks/` are the best examples: [`fvm_check.dart`](../../../packages/appstein_engine/lib/src/doctor/checks/fvm_check.dart) is a short one.

## 1. Create the check

**File:** `packages/appstein_engine/lib/src/doctor/checks/<name>_check.dart`

Write a `final class` with a `const` constructor that implements `DoctorCheck`, from [`doctor_check.dart`](../../../packages/appstein_engine/lib/src/doctor/doctor_check.dart):

- **`id`** is `doctor.<name>`, such as `doctor.fvm`. Keep it stable once added: tests find a check by its ID. Write it as a string literal in this file (`String get id => 'doctor.<name>';`), because `gen_docs` finds the check's declaration by that literal.
- **`title`** is the short name people see at the start of the check's line, such as `FVM`.
- **`run(context)`** returns a `CheckResult` and **never throws**. Doctor does catch a throw, but it reports it as "The check itself failed" and a bug in Appstein. Turn every expected failure into a result: a missing tool is a `warning` or an `error` with a fix hint, and a check that doesn't apply (the wrong OS, no project) is `skipped`.
- **Reach the machine only through the context:**
  - `context.environment` for environment variables, the PATH and the OS;
  - `context.runner` to run tools;
  - `context.sdk` for the Flutter SDK, which is already detected. Don't detect it again.
- **Run a tool by the full path** that `findExecutable` returns. On Windows a bare name only finds `.exe` files, so a `.bat` tool such as `fvm` would look "not installed". See [running-tools](../running-tools.md).

A check that only asks "is this command installed, and what version?" needs no new class: add a `ToolCheck` constant next to `gitCheck` and `ripgrepCheck` in [`tool_check.dart`](../../../packages/appstein_engine/lib/src/doctor/checks/tool_check.dart).

## 2. Write its doc comment

**File:** the same one.

Put a `///` comment on the class (or on the `ToolCheck` constant). **Its first paragraph becomes the check's row in [doctor](../doctor.md#the-checks)**, so write it for a person reading the guide: what the check looks at, and why. `gen_docs` stops with an error if the comment is missing.

Every other public member needs a `///` comment too, such as the constructor's `/// Creates the check.`; `dart analyze` enforces that.

## 3. Add it to the default checks

**File:** [`doctor.dart`](../../../packages/appstein_engine/lib/src/doctor/doctor.dart)

Add it to the list in `defaultDoctorChecks()`, at the place it should appear in the output. The list order is the display order. Related checks sit together: Flutter, Dart and FVM first, then the Android and Apple tools.

## 4. Export it

**File:** [`appstein_engine.dart`](../../../packages/appstein_engine/lib/appstein_engine.dart)

Add an `export` line for the new file, in alphabetical order. The CLI, the repo tools and the tests all import the engine through this file. A new `ToolCheck` constant needs nothing, because `tool_check.dart` is already exported.

## 5. Test it

**File:** `packages/appstein_engine/test/doctor/checks/<name>_check_test.dart`

Test at least one passing case and one failing case, with the fakes from `packages/appstein_engine/test/support/`:

- `testContext` builds a context: Flutter 3.47.5 found, an empty environment and a runner that knows no commands. Pass your own `environment`, `runner`, `sdk` or `projectRoot`.
- `fakeEnvironment` sets environment variables, and `fakeExecutable` in a `tempDir` puts a tool on a fake PATH.
- `FakeProcessRunner.when` sets what a command prints; a command you didn't set up "fails to start", like a missing tool.

[`tool_check_test.dart`](../../../packages/appstein_engine/test/doctor/checks/tool_check_test.dart) shows both cases in a few lines. [testing](../testing.md) explains every helper.

## 6. If it mirrors Flutter, extend the cross-check

**File:** [`doctor_real_environment_test.dart`](../../../packages/appstein_engine/test/integration/doctor_real_environment_test.dart)

If the check reports something Flutter also decides, such as which SDK or JDK is used, add a test that compares its answer with Flutter's own output on the real machine. Unit tests can only check our model of Flutter; this test checks the model. CI runs it on Linux, Windows and macOS. See [doctor](../doctor.md#a-rule-the-checks-follow) for why.

## 7. Update the guide

From the repo root:

```powershell
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

The first command adds the new row to [doctor](../doctor.md#the-checks). Read it in place, and update doctor.md's prose if the check needs more explanation than one row. The second command checks the guide, including that doctor.md changed along with the code.
