<!-- covers: packages/appstein_lints/lib/src/appstein_lints_plugin.dart -->

# How to: add a lint rule

These steps add a rule to the `appstein_lints` analyzer plugin. Read [lints](../lints.md) first for how the plugin is loaded. The one existing rule, [`layer_imports_rule.dart`](../../../packages/appstein_lints/lib/src/layer_imports/layer_imports_rule.dart), is the example to follow. Which rules M1 plans is in [spec §9.6](../../superpowers/specs/2026-09-29-appstein-design.md#96-lint-rules-in-m1-appstein_lints-one-test-file-per-rule).

## 1. Write the rule class

**File:** `packages/appstein_lints/lib/src/<rule_name>/<rule_name>_rule.dart`

- **Extend `AnalysisRule`** when the rule reports one kind of problem, and give it a `diagnosticCode`. **Extend `MultiAnalysisRule`** when it reports several, and list them in `diagnosticCodes`. `LayerImportsRule` is a `MultiAnalysisRule`, because an invalid config is reported differently from a forbidden import.
- **Call the super constructor** with the rule's `name` and a one-line `description`.
- **Declare each diagnostic as a `static const LintCode`:**
  - the first argument is the rule's name;
  - the message may use `{0}`, `{1}` and so on, filled from the `arguments` you report with;
  - `correctionMessage` says how to fix it;
  - with several codes, give each a `uniqueName`, such as `layer_imports_forbidden`.
- **Override `registerNodeProcessors`.** Add a visitor for only the node types the rule needs, for example `registry.addImportDirective(this, visitor)`. The visitor extends `SimpleAstVisitor<void>`, and reports with `rule.reportAtNode(...)`, passing the `diagnosticCode` and `arguments`. If the rule doesn't apply to a file, register nothing, so the file costs nothing.

Every public member needs a `///` comment; `dart analyze` enforces that. The lints package may import only `appstein_protocol` among our packages, and `layer_imports` checks that too.

## 2. Register it in the plugin

**File:** [`appstein_lints_plugin.dart`](../../../packages/appstein_lints/lib/src/appstein_lints_plugin.dart)

In `AppsteinLintsPlugin.register`, add `registry.registerLintRule(<YourRule>())` next to the existing one. `registerLintRule` makes it a lint: **off until a project turns it on**. That is how our rules work, so a project chooses which ones it wants.

## 3. Name its diagnostic

The rule's name, the first argument of its `LintCode`, is the name people write in `analysis_options.yaml` and see in the analyzer's output. Use lowercase words joined by `_`, like the Dart team's own lints: `layer_imports`, not `LayerImports`.

## 4. Turn it on in `analysis_options.yaml`

**File:** [`analysis_options.yaml`](../../../analysis_options.yaml)

Add the rule's name under `plugins:`, `appstein_lints:`, `diagnostics:`, next to `layer_imports: true`. This turns it on for our own repo; without it, the rule never runs here.

## 5. Test it

**File:** `packages/appstein_lints/test/<rule_name>_rule_test.dart` (one test file per rule, spec §9.6)

Use `package:analyzer_testing`, as [`layer_imports_rule_test.dart`](../../../packages/appstein_lints/test/layer_imports_rule_test.dart) does:

- a test class extends `AnalysisRuleTest` and is marked `@reflectiveTest`;
- `setUp` sets `rule` to a new instance of your rule, then calls `super.setUp()`;
- each `test_…` method writes files with `newFile` and checks them with `assertDiagnosticsInFile` (each expected problem as `lint(offset, length)`) or `assertNoDiagnosticsInFile`;
- `main` calls `defineReflectiveTests` inside `defineReflectiveSuite`.

Test a file that breaks the rule and one that doesn't. Run the tests with `fvm dart test` in `packages/appstein_lints`. [testing](../testing.md#lint-tests) explains the setup.

## 6. Restart the analysis server

The analysis server compiles the plugin when it starts, so your IDE keeps running the old code until you restart it. In VS Code, run "Dart: Restart Analysis Server". `fvm dart analyze --fatal-infos` from the repo root always starts fresh, and is the check CI runs. See [debugging](../debugging.md#the-analyzer-plugin).

## 7. Update the guide

**File:** [lints](../lints.md)

Add a section for the new rule: what it enforces, and where it reads any settings. lints.md covers `packages/appstein_lints/lib/`, so the guide check expects it to change with the rule. Then, from the repo root:

```powershell
fvm dart run tool/check_guide.dart --since main
```
