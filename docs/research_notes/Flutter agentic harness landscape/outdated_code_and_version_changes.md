# Outdated Flutter/Dart Code from AI Agents: Version Changes and Mitigations (as of 2026-09-28)

## Q1. Current stable Flutter/Dart versions and release history since Flutter 3.19 / Dart 3.3

### Takeaway
As of 2026-09-28 the current stable is **Flutter 3.47.5 / Dart 3.13.4** (released 2026-09-18). Since Flutter 3.19 (Feb 2024) there have been **10 more quarterly stable minors** (3.22 → 3.47). Anything an LLM "remembers" from 2023-2024 training data is 8-11 releases stale. The next stable ("Fall", November 2026) is expected to formally deprecate `package:flutter/material.dart` and `package:flutter/cupertino.dart`.

### Cited Findings
- The official machine-readable releases manifest lists current stable as `3.47.5` (hash `6a19cca5...`), released 2026-09-18, Dart 3.13.4 — [releases_linux.json](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
- Stable release dates (x.y.0), each with its bundled Dart version, from the same manifest — [releases_linux.json](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json):
  | Flutter | Date | Dart | Latest patch (date, Dart) |
  |---|---|---|---|
  | 3.19.0 | 2024-02-15 | 3.3.0 | 3.19.6 (2024-04-17, 3.3.4) |
  | 3.22.0 | 2024-05-13 | 3.4.0 | 3.22.3 (2024-07-18, 3.4.4) |
  | 3.24.0 | 2024-08-06 | 3.5.0 | 3.24.5 (2024-11-14, 3.5.4) |
  | 3.27.0 | 2024-12-11 | 3.6.0 | 3.27.1 (2024-12-16, 3.6.0) |
  | 3.29.0 | 2025-02-12 | 3.7.0 | 3.29.3 (2025-04-14, 3.7.2) |
  | 3.32.0 | 2025-05-20 | 3.8.0 | 3.32.8 (2025-07-25, 3.8.1) |
  | 3.35.0 | 2025-08-14 | 3.9.0 | 3.35.7 (2025-10-23, 3.9.2) |
  | 3.38.0 | 2025-11-12 | 3.10.0 | 3.38.10 (2026-02-11, 3.10.9) |
  | 3.41.0 | 2026-02-11 | 3.11.0 | 3.41.9 (2026-04-30, 3.11.5) |
  | 3.44.0 | 2026-05-18 | 3.12.0 | 3.44.9 (2026-08-06, 3.12.2) |
  | 3.47.0 | 2026-08-12 | 3.13.0 | 3.47.5 (2026-09-18, 3.13.4) |
- The release-notes index says "Flutter 3.47 is here!" and lists 3.47.0 as newest, with per-release links to announcements, notes and breaking changes (the page itself carries no dates) — [Flutter release notes](https://docs.flutter.dev/release/release-notes)
- Dart release dates from the language evolution page: 3.3 (2024-02-15), 3.4 (2024-05-14), 3.5 (2024-08-06), 3.6 (2024-12-11), 3.7 (2025-02-12), 3.8 (2025-05-20), 3.9 (2025-08-13), 3.10 (2025-11-12), 3.11 (2026-02-09), 3.12 (2026-05-18), 3.13 (2026-08-12) — [Dart language evolution](https://dart.dev/resources/language/evolution)
- Flutter 3.47 was announced 2026-08-12. Material/Cupertino libraries in the core SDK are "scheduled for formal deprecation in the Fall stable release (November)" — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)

### Inferences
- The release cadence has been steady at roughly quarterly (Feb/May/Aug/Nov), and each Flutter minor ships with a new Dart minor. A harness can therefore predict the next stable (a Flutter 3.50-ish / Dart 3.14-ish in ~Nov 2026). **This is an extrapolation and the version number is not confirmed.**
- Models with training cutoffs in 2025 will typically know Flutter ≤3.29–3.35. They will not know dot shorthands (Dart 3.10), primary constructors (3.13), or the `material_ui` split (3.47).

### Gaps
- I did not find an official announcement of the November 2026 version number.
- `releases_linux.json` dates are publish timestamps, which can differ by a day from the blog announcement dates (e.g., 3.35.0 is 2025-08-14 in the manifest vs Dart 3.9 2025-08-13 on dart.dev).

---

## Q2. Most impactful Flutter deprecations/breaking changes since ~2024 (dated catalog)

### Takeaway
The primary index is docs.flutter.dev/release/breaking-changes, organized per release. The changes most likely to trip LLMs fall into three groups:
- **High-frequency APIs deprecated 2023-2025:** `withOpacity`, `MaterialState*`, `WillPopScope`, `textScaleFactor`, `RawKeyEvent`, the `*Theme` → `*ThemeData` normalization, `Radio` groupValue, `DropdownButtonFormField.value`.
- **Build-system changes:** v1 embedding removed, imperative Gradle apply, built-in Kotlin/AGP 9.
- **The 2026 Material/Cupertino decoupling into `material_ui` / `cupertino_ui`.** This one invalidates the single most common line in all Flutter code: `import 'package:flutter/material.dart';`.

### Cited Findings
Unless noted, each item below is listed verbatim under its release heading on the [Flutter breaking-changes index](https://docs.flutter.dev/release/breaking-changes). Release dates come from the Q1 table.

**Not yet released to stable (as of 2026-09):**
- "Migrate to standalone `material_ui` and `cupertino_ui` packages"; "Removal of `useInheritedMediaQuery`"; "Added enabled property and made onChanged optional for DropdownButton"; "Restrict command-line flags for prebuilt Android release binaries" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.47 (2026-08-12):**
- "Removal of `describeEnum`" (it was deprecated in 3.16). Also: "OpenGL ES render-to-texture content is stored top-down"; "Update semantics header and headingLevel behavior on iOS and Android" — [index](https://docs.flutter.dev/release/breaking-changes)
- Standalone `material_ui` / `cupertino_ui` reached 1.0 alongside 3.47. The migration is `dart fix --apply --code=migrate_design_widgets`. Contributions to in-framework `material.dart` / `cupertino.dart` "were frozen starting in Flutter 3.44" — [Migrate to standalone material_ui and cupertino_ui](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui)
- Import change: `package:flutter/material.dart` → `package:material_ui/material_ui.dart`, and `package:flutter/cupertino.dart` → `package:cupertino_ui/cupertino_ui.dart`. Localizations simplify to `localizationsDelegates: GlobalMaterialLocalizations.delegates`. dart fix may not add the pubspec deps ("manually add them"). The doc also says "the compatibility bridge cannot resolve type mismatches when a dependency exposes, accepts, or returns in-framework SDK types in its public API signatures." — [same page](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui)
- 1.0.0 of the packages was published to pub.dev around 2026-08-13. In November 2026 (Fall stable) the old imports become formally deprecated and emit analyzer warnings — [Flutter blog: Material and Cupertino decoupling are here](https://flutter.dev/blog/decoupling-material-cupertino) (via search summary); [material_ui on pub.dev](https://pub.dev/packages/material_ui)
- Impeller becomes the default renderer on macOS, Windows and Linux, replacing Skia. Web Wasm is still opt-in (`flutter build web --release --wasm`) with work "toward enabling Wasm by default". Android toolchain is verified against Java 17, KGP 2.4.0, AGP 9.1.0, Gradle 9.3.1 — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)

**Flutter 3.44 (2026-05-18):**
- "Migrating Flutter Android projects to built-in Kotlin"; "Page transition builders reorganization"; "Deprecate `onReorder` callback"; "Deprecated `cacheExtent` and `cacheExtentStyle`"; "`IconData` class marked as `final`"; "Deprecate `TextInputConnection.setStyle`"; "ListTile reports an error in debug when wrapped in a colored widget"; "Changing RawMenuAnchor close order"; "Large screen orientation and resizability restrictions ignored on Android 17" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.41 (2026-02-11):**
- "Deprecate `findChildIndexCallback` in favor of `findItemIndexCallback`" (ListView/SliverList separated); "Deprecate `containsSemantics` in favor of `isSemantics`"; "`FontWeight` also controls the weight attribute of variable fonts"; "Material 3 tokens update"; "Merged threads on Linux" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.38 (2025-11-12):**
- "The default page transition on Android is now `PredictiveBackPageTransitionBuilder`"; "SnackBar with action no longer auto-dismisses"; "UISceneDelegate adoption" (iOS); "Deprecate `OverlayPortal.targetsRootOverlay`"; "Deprecate `SemanticsProperties.focusable`…"; "`CupertinoDynamicColor` wide gamut support" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.35 (2025-08-14):**
- "Redesigned the `Radio` widget"; "Deprecate `DropdownButtonFormField` `value` parameter in favor of `initialValue`"; "Component theme normalization updates"; "Deprecate app bar color"; "The `Form` widget no longer supports being a sliver"; "Flutter now sets default `abiFilters` in Android builds"; "Merged threads on macOS and Windows"; "`$FLUTTER_ROOT/version` replaced by `$FLUTTER_ROOT/bin/cache/flutter.version.json`" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.32 (2025-05-20):**
- "Deprecate `ExpansionTileController` in favor of `ExpansibleController`"; "Deprecate `ThemeData.indicatorColor` in favor of `TabBarThemeData.indicatorColor`"; "Material Theme System Updates"; "Localized messages are generated into source, not a synthetic package" (breaks `package:flutter_gen` imports); "`.flutter-plugins-dependencies` replaces `.flutter-plugins`"; "Deprecate `InputDecoration.maintainHintHeight` in favor of `maintainHintSize`" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.29 (2025-02-12):**
- "Removal of v1 Android embedding Java APIs"; "Deprecate `ThemeData.dialogBackgroundColor` in favor of `DialogThemeData.backgroundColor`"; "Updated Material 3 `Slider`"; "Updated Material 3 progress indicators" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.27 (2024-12-11):**
- "`Color` wide gamut support" (the change that deprecated `Color.withOpacity` / `.opacity` / `.red` etc. in favor of `withValues(alpha:)`, `.a`, `.r`); "Component theme normalization" (`CardTheme` → `CardThemeData` etc.); "Set default for SystemUiMode to Edge-to-Edge"; "Material 3 Tokens Update"; "Remove invalid parameters for `InputDecoration.collapsed`" — [index](https://docs.flutter.dev/release/breaking-changes)
- `withOpacity()` was deprecated in 3.27, replaced by `withValues()`, e.g. `Colors.white.withValues(alpha: 0.96)` — [Medium: Migrating from withOpacity to withValues](https://hasan-hammoudah.medium.com/migrating-from-withopacity-to-withvalues-in-flutter-3-27-what-you-need-to-know-9d4f81d4adab)

**Flutter 3.24 (2024-08-06):**
- "Generic types in `PopScope`"; "Deprecate `ButtonBar` in favor of `OverflowBar`"; "Navigator's page APIs breaking change"; "New APIs for Android plugins that render to a `Surface`" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.22 (2024-05-13):**
- "Rename `MaterialState` to `WidgetState`" (`MaterialStateProperty` → `WidgetStateProperty`, etc.); "Introduce new `ColorScheme` roles" (the deprecation of `background`/`onBackground`/`surfaceVariant` falls under this entry); "Dropping support for Android KitKat"; "Nullable `PageView.controller`"; "Deprecated API removed after v3.19" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.19 (2024-02-15):**
- "Migrate RawKeyEvent/RawKeyboard system to KeyEvent/HardwareKeyboard system"; "Deprecate imperative apply of Flutter's Gradle plugins" (the `plugins {}` DSL replaces `apply from: .../flutter.gradle`); "Stop generating `AssetManifest.json`" — [index](https://docs.flutter.dev/release/breaking-changes)

**Flutter 3.16 (Nov 2023; older baseline that LLMs still get wrong):**
- "The `ThemeData.useMaterial3` property is now set to true by default"; "Deprecate `textScaleFactor` in favor of `TextScaler`"; "Deprecated just-in-time navigation pop APIs for Android Predictive Back" (this deprecated `WillPopScope` in favor of `PopScope`); "Deprecate `describeEnum`" — [index](https://docs.flutter.dev/release/breaking-changes)
- `PopScope(canPop: false, onPopInvoked: ...)` replaces `WillPopScope(onWillPop: ...)` — [search summary of multiple sources](https://github.com/flutter/flutter/issues/139243)

### Inferences
- **Highest-risk item for FlutterCraft: the `material_ui` decoupling.** Essentially 100% of training-data Flutter files begin with `import 'package:flutter/material.dart';`, and after Nov 2026 that line will produce deprecation warnings. An agent will regenerate it in every new file, so a harness should post-process or rule-enforce it. The situation is transitional until the Fall release: both imports still work.
- The next tier of common LLM mistakes (my ranking by how often these APIs appear in typical app code; not measured):
  1. `withOpacity`
  2. `MaterialStateProperty`
  3. `WillPopScope` / `onPopInvoked` (3.24 generic `PopScope<T>`; `onPopInvokedWithResult` replaced `onPopInvoked`. That rename is from memory and unverified.)
  4. `textScaleFactor`
  5. `CardTheme(...)` passed to `ThemeData.cardTheme` (now `CardThemeData`)
  6. `Radio(groupValue:, onChanged:)` (3.35 redesign introduces a `RadioGroup` ancestor; details from memory, unverified)
  7. `DropdownButtonFormField(value:)`
  8. `ButtonBar`
  9. `ColorScheme.background`
  10. `useMaterial3: true` (redundant)
  11. `RawKeyboardListener`
- Build-file mistakes are the ones agents fail on hardest, because `dart fix` does not touch Gradle: old `apply plugin:` / `apply from: flutter.gradle` Groovy, v1 embedding, and missing built-in Kotlin/AGP 9 config.
- Impeller defaults, as best I know: iOS default since 3.10, Android default since roughly 3.22/3.27 (from memory, **unverified**), desktop default in 3.47 (verified). As a result, agents may suggest obsolete `--enable-impeller` / Skia flags or shader-warmup workarounds.

### Gaps
- I did not open the individual breaking-change pages (e.g., Radio redesign, Component theme normalization, PopScope generics), so the exact before/after APIs for those items are stated from memory and should be verified before becoming harness rules.
- The web HTML renderer removal (believed deprecated ~3.24 and removed ~3.29) did not appear on the breaking-changes index. I did not verify it.
- I did not verify whether the Android Gradle "Kotlin DSL by default for new projects" change has its own breaking-change entry.

---

## Q3. New Dart language features since Dart 3.0, macros status, and tooling changes

### Takeaway
Dart has shipped language features almost every release:
- **Dart 3.0:** records, patterns, class modifiers/sealed, switch expressions
- **Dart 3.3:** extension types
- **Dart 3.6:** digit separators
- **Dart 3.7:** wildcard `_` and the "tall style" formatter
- **Dart 3.8:** null-aware elements and formatter trailing-comma changes
- **Dart 3.10:** dot shorthands
- **Dart 3.12:** private named parameters
- **Dart 3.13 (Aug 2026):** primary constructors and concise `new`/`factory` constructor syntax

Macros were **cancelled in January 2025**. Augmentations are the pared-back replacement, and they do not remove the need for build_runner.

### Cited Findings
- Per-version features and dates — [Dart language evolution](https://dart.dev/resources/language/evolution):
  - 3.0 (2023-05-10): patterns, records, class modifiers, switch expressions, if-case
  - 3.2 (2023-11-15): private final field promotion
  - 3.3 (2024-02-15): extension types
  - 3.4–3.5: inference tweaks only
  - 3.6 (2024-12-11): digit separators
  - 3.7 (2025-02-12): wildcard variables; `dart format` tied to language version with the new "tall style"
  - 3.8 (2025-05-20): null-aware elements (`[?x]`); formatter "intelligent trailing comma placement"
  - 3.9 (2025-08-13): null safety assumed for promotion/reachability
  - 3.10 (2025-11-12): dot shorthands (e.g., `.center` in place of `MainAxisAlignment.center`)
  - 3.11 (2026-02-09): no new features; better analyzer/editor support for dot shorthands
  - 3.12 (2026-05-18): private named parameters
  - 3.13 (2026-08-12): primary constructors, plus concise constructor syntax using `new`/`factory` instead of repeating the class name
- Macros were cancelled in January 2025 because re-execution during incremental compilation hurt hot reload. The team instead plans to ship augmentations (split class definitions with `augment`), which "improve how generated code integrates, but do not eliminate build_runner" — [Dart blog: An update on Dart macros & data serialization](https://dart.dev/language/macros); [HN discussion](https://news.ycombinator.com/item?id=42871867); [dart-lang/language#4256 scoping augmentations](https://github.com/dart-lang/language/issues/4256)

### Inferences
- LLM failure modes here run in both directions:
  - **Under-use:** writing verbose pre-3.10 code such as `MainAxisAlignment.center`, full constructors instead of primary constructors, `if (x != null) x` in lists instead of `?x`, and classic class hierarchies instead of `sealed` + switch expressions. None of this is wrong, but it is non-idiomatic and conflicts with current `dart format` output.
  - **Over-use/hallucination:** models trained on 2024 hype may emit `@JsonCodable()` macros or `augment` syntax that doesn't compile.
- New syntax is gated on the pubspec `environment: sdk:` lower bound (language versioning). Using dot shorthands or primary constructors with `sdk: ^3.5.0` fails to compile. The harness should therefore tell the agent the package's effective language version, not just the installed SDK. (This inference comes from how Dart language versioning works generally.)
- Formatter churn (tall style in 3.7, trailing-comma handling in 3.8) means agents trained on old style will fight `dart format`. Always running `dart format` after edits neutralizes this.

### Gaps
- I did not verify changes to `package:lints` / `flutter_lints` recommended sets (e.g., new default lints in flutter_lints 5/6) or analyzer diagnostic-name changes in 2025-2026.
- I did not verify whether augmentations have shipped in any stable Dart version as of 3.13. The evolution page does not list them, which suggests not.

---

## Q4. Evidence that LLMs produce outdated (Flutter) code

### Takeaway
Rigorous evidence exists for LLMs generally, mainly Python. It shows deprecated-API usage is systematic and prompt-context-dependent, and that even top models solve only ~half of version-conditioned tasks. Flutter-specific evidence is mostly practitioner-level:
- Flutter's own official "AI rules" and MCP docs exist largely to counter this.
- Medium posts and community MCP servers ship explicit deprecated-pattern validators.

I found no peer-reviewed Flutter/Dart-specific benchmark.

### Cited Findings
- Wang et al., "LLMs Meet Library Evolution" (ICSE 2025): the first study of deprecated API usage in LLM code completion, covering 7 LLMs, 145 deprecated→replacement API mappings from 8 Python libraries, and 28,125 prompts built from 9,022 outdated and 19,103 up-to-date functions — [arXiv 2406.09834](https://arxiv.org/abs/2406.09834); [ICSE'25 DOI](https://dl.acm.org/doi/10.1109/ICSE55347.2025.00245)
  - Findings: "All evaluated LLMs encounter challenges in predicting plausible API usages and face issues with deprecated API usages, due to the presence of deprecated API usages during model training and the absence of API deprecation knowledge during model inference."
  - Performance "differs significantly" depending on whether the surrounding context comes from outdated or up-to-date code. So the existing code in the file steers the model toward old or new APIs — [arXiv PDF p.2](https://arxiv.org/pdf/2406.09834)
- GitChameleon 2.0: 328 version-conditioned Python problems with execution tests. "Enterprise models achieving baseline success rates in the 48-51% range", and "all tested systems encounter significant challenges" — [arXiv 2507.12367](https://arxiv.org/abs/2507.12367); published at [ACL 2026](https://aclanthology.org/2026.acl-long.2170/); [benchmark repo](https://github.com/mrcabbage972/GitChameleonBenchmark)
- Follow-up work tries to update model API knowledge via RL — [ReCode, arXiv 2506.20495](https://arxiv.org/pdf/2506.20495). A TOSEM paper evaluates LLMs updating deprecated API usage from natural-language descriptions — [ACM TOSEM](https://dl.acm.org/doi/10.1145/3808230)
- Flutter's official docs provide "AI rules" (rules.md, rules_10k.md and other size variants) to steer AI editors toward current practices — [Flutter AI rules](https://docs.flutter.dev/ai/ai-rules); [source](https://github.com/flutter/website/blob/main/src/content/ai/ai-rules.md)
- A practitioner article, "AI and Flutter: Preventing Deprecated Code with Rules, Pinning, and CI" (Jan 2026), makes these recommendations (per search snippet; the page returned 403 to direct fetch) — [Medium, Brayan Tiwa](https://medium.com/@tiwabrayan/ai-and-flutter-preventing-deprecated-code-with-rules-pinning-and-ci-7b17595995d9):
  - include explicit SDK/package versions in prompts
  - give short modern examples
  - run `dart analyze` / `dart fix` in CI
- Community Flutter MCP servers ship hard-coded deprecated-API validators, e.g. `flutter_mcp_2`'s `apiPatterns.js` — [glama: flutter_mcp_2 apiPatterns.js](https://glama.ai/mcp/servers/@dvillegastech/flutter_mcp_2/blob/1097e809678b455a4e2ce6fafe2863fbb36df95b/src/validators/apiPatterns.js). The community rules repo evanca/flutter-ai-rules provides "Flutter AI Skills and Rules for Claude, Codex, Cursor" — [GitHub](https://github.com/evanca/flutter-ai-rules)
- A critical take on how the official AI rules get used — [Medium, Yuri Novicow, "AI rules for Flutter development. We should not use them as intended."](https://medium.com/easy-flutter/ai-rules-for-flutter-development-44750fe231a6) (not read in full)

### Inferences
- The ICSE finding that surrounding context steers the model matters directly for FlutterCraft. In a legacy project full of `withOpacity`, the agent will keep writing `withOpacity`, so the harness needs post-generation checks, not just prompt rules.
- The existence of official Flutter AI rules, an official MCP server, official agent skills, and multiple community deprecated-pattern validators is strong circumstantial evidence that the Flutter team and community see stale code generation as a real, recurring problem. (Inference; no Flutter-team statement quantifying it was found.)

### Gaps
- No quantitative Flutter/Dart-specific benchmark of deprecated API usage by LLMs was found. That makes a good opportunity for FlutterCraft to build an internal eval, e.g., a GitChameleon-style set of Flutter tasks checked by `flutter analyze` with `deprecated_member_use` counts.
- I did not retrieve concrete Reddit/HN threads with specific agent failure anecdotes (search returned tangential results).
- I did not extract exact per-model deprecated-usage-rate (DUR) numbers from the ICSE paper; only the qualitative findings and the fix rate below.

---

## Q5. Mitigations and the evidence for each

### Takeaway
The best evidence supports **deterministic post-generation replacement plus execution/analyzer feedback**:
- ICSE'25: REPLACEAPI-style direct replacement fixed >85% of deprecated usages, while prompt-insertion (INSERTPROMPT) was "not sufficient."
- GitChameleon: RAG gave up to ~10% improvement, and visible tests enable self-debugging.

For Flutter, the equivalent tooling is:
1. analyzer `deprecated_member_use` diagnostics
2. `dart fix --apply` backed by fix_data.yaml, including the new `migrate_design_widgets` code
3. the official Dart/Flutter MCP server (analyzer, symbol resolution, tests)
4. the Google Developer Knowledge MCP for docs
5. official rules and agent skills

I found no head-to-head evaluation of these for Flutter.

### Cited Findings
- **Replace vs prompt (ICSE'25):** "REPLACEAPI effectively addresses deprecated API usages for all evaluated open-source LLMs, achieving fix rates exceeding 85% with acceptable accuracy… While INSERTPROMPT does not currently achieve sufficient effectiveness and accuracy in fixing completions containing deprecated API usage, it shows potential" — [arXiv 2406.09834 PDF, p.2](https://arxiv.org/pdf/2406.09834)
- **RAG and self-debug (GitChameleon):** the benchmark includes visible tests for self-debugging and documentation references for RAG. "Many models exhibit a significant (up to 10%) boost in success rate with RAG compared to greedy decoding alone" (search-result summary of the paper) — [arXiv 2507.12367](https://arxiv.org/html/2507.12367v2)
- **Data-driven fixes (fix_data):**
  - Flutter's `packages/flutter/lib/fix_data/` holds YAML rule files used by the `dart fix` framework (IDE quick fixes plus the CLI). Layout is `fix_material.yaml`, `fix_widgets.yaml`, and per-class files like `fix_data/fix_material/fix_app_bar.yaml`, max ~50 rules per file.
  - Tests live in `packages/flutter/test_fixes` and run via `dart fix --compare-to-golden`; they are also run from the Dart SDK's CI.
  - Source: [flutter/flutter fix_data README](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/fix_data/README.md)
- **Design-package migration via dart fix:** `dart fix --apply --code=migrate_design_widgets` rewrites the imports but may not add pubspec deps — [breaking change page](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui)
- **Official Dart & Flutter MCP server:**
  - Started with `dart mcp-server`; provides "real-time access to analyzer diagnostics, symbol resolution, test runners, and runtime inspection".
  - Supports Claude Code, Codex, Cursor, Copilot, Antigravity, and other MCP clients.
  - Pairs with official Agent Skills installed via `npx skills add flutter/agent-plugins …` and `npx skills add dart-lang/skills …`.
  - Source: [Flutter docs: MCP server](https://docs.flutter.dev/ai/mcp-server)
- **Google Developer Knowledge API + MCP (public preview):** a "programmatic source of truth" for Google developer docs, returning pages as Markdown. It requires a Google Cloud API key and is enabled via gcloud. Flutter docs recommend it "to give your assistant search access to official Flutter and Dart documentation" — [Google Developers Blog](https://developers.googleblog.com/introducing-the-developer-knowledge-api-and-mcp-server/); [MCP setup](https://developers.google.com/knowledge/mcp); [Flutter: Get started with AI](https://docs.flutter.dev/ai/get-started); [InfoWorld coverage](https://www.infoworld.com/article/4128405/google-unveils-api-and-mcp-server-for-developer-documentation.html)
- **Rules files:** Flutter publishes official rules templates in several size tiers (rules.md, rules_10k.md…) and notes "support for rules files is still evolving" — [Flutter AI rules](https://docs.flutter.dev/ai/ai-rules)
- **Practitioner recommendations:** pin SDK and package versions in prompts, include modern examples, and run `dart analyze` / `dart fix` / `flutter fix` in CI — [Medium, Brayan Tiwa (search snippet)](https://medium.com/@tiwabrayan/ai-and-flutter-preventing-deprecated-code-with-rules-pinning-and-ci-7b17595995d9). One practitioner argues AI rules should live outside tool-specific files like Cursor rules — [Ivan Morgillo, 2026-05-29](https://www.ivanmorgillo.com/2026/05/29/ai-coding-rules-should-not-live-in-cursor-rules/)

### Inferences
- **Recommended layered design for FlutterCraft** (from the evidence above; not itself evaluated):
  1. **Pre-generation:** inject a short, auto-generated "version delta" block into the agent context. It should give the project's actual Flutter/Dart versions (from `flutter --version --machine` / pubspec `sdk:` bound) and the top ~20 deprecated→replacement pairs relevant to that version. ICSE shows prompting alone is weak, so keep this short.
  2. **In-loop:** wire the official `dart mcp-server` so the agent calls the analyzer itself, plus the Developer Knowledge MCP (or Context7) for doc lookup.
  3. **Post-generation (strongest evidence):** a hook after every edit runs `dart format`, `dart fix --apply`, and `dart analyze`/`flutter analyze`. It fails or feeds back on any `deprecated_member_use` / `deprecated_member_use_from_same_package` diagnostic. This mirrors REPLACEAPI (deterministic replacement) plus GitChameleon-style self-debugging.
  4. **CI gate:** zero deprecation warnings.
- `dart fix` coverage is partial: it only covers APIs the Flutter team wrote fix_data rules for. Build files (Gradle, AndroidManifest, iOS SceneDelegate), behavioral changes (SnackBar auto-dismiss, predictive-back transitions), and structural rewrites (Radio → RadioGroup, likely) need rules text or custom checks.
- Context7 and similar third-party doc MCPs have no Flutter-specific evaluation that I found. Their benefit is plausibly similar to GitChameleon's RAG (~single-digit to 10% gains), but that is unproven for Dart.

### Gaps
- I found no public evaluation comparing Context7 vs the Developer Knowledge MCP vs the Dart MCP server vs rules files for Flutter code quality.
- I did not measure how many of the Q2 deprecations have fix_data rules. That would require listing the YAML files in `packages/flutter/lib/fix_data/` and grepping for `withOpacity`, `WillPopScope`, `MaterialState`, etc. (planned as a follow-up; not done here).
- I did not confirm whether `WillPopScope` → `PopScope` is auto-fixable. The semantics differ (`canPop` + `onPopInvokedWithResult` vs an async `onWillPop`), which suggests it is not a simple rename. Inference only.

---

## Q6. Machine-readable sources for auto-generating a "version delta" guide

### Takeaway
Yes, several usable sources exist:
1. **releases_linux/windows/macos.json** — authoritative version → date → Dart version mapping.
2. **fix_data YAML** in flutter/flutter — deterministic deprecated→replacement transforms keyed by version.
3. **The breaking-changes index plus per-change pages** — Markdown in the flutter/website repo, organized by "Released in Flutter X.Y".
4. **The dart.dev language evolution page and Dart CHANGELOG** — language features by version.
5. **Analyzer output (`deprecated_member_use`)** — the ground-truth, project-specific signal at runtime.

### Cited Findings
- `https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json` provides `current_release` plus per-release `version`, `release_date`, `dart_sdk_version`, `hash`, and `channel` — [releases_linux.json](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
- fix_data YAML files are organized per library/class and consumed by `dart fix`, with golden tests in `test_fixes` — [fix_data README](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/fix_data/README.md)
- The breaking-changes index groups every change under "Released in Flutter X.Y" plus "Not yet released to stable", with per-release anchors (e.g., `#released-in-flutter-3-47`) — [breaking-changes index](https://docs.flutter.dev/release/breaking-changes); [release notes index](https://docs.flutter.dev/release/release-notes)
- The Flutter website content is Markdown in `flutter/website` under `src/content/…`, e.g. `src/content/ai/ai-rules.md` — [flutter/website](https://github.com/flutter/website/blob/main/src/content/ai/ai-rules.md)
- Dart language features are listed per version with dates — [Dart language evolution](https://dart.dev/resources/language/evolution)
- Flutter's docs expose rules files and an MCP server designed for machine consumption — [AI rules](https://docs.flutter.dev/ai/ai-rules); [MCP server](https://docs.flutter.dev/ai/mcp-server)

### Inferences
- **Proposed pipeline** (inference, not tested):
  1. Read the project's Flutter version (`flutter --version --machine`) and pubspec SDK bound.
  2. Diff against `releases_*.json` to get the list of releases between the model's assumed knowledge (say 3.24) and the installed version.
  3. Pull the matching "Released in Flutter X.Y" sections from the flutter/website Markdown. The breaking-changes pages are likely under `src/content/release/breaking-changes/`, extrapolated from the ai-rules path and unverified.
  4. Parse fix_data YAML at the installed SDK's git tag (`$FLUTTER_ROOT/packages/flutter/lib/fix_data/`, available locally in every Flutter SDK install) to extract `element → replacement` pairs.
  5. Compress to a ≤2k-token cheat sheet.
- **fix_data is available offline in the user's installed SDK**, so FlutterCraft can generate an exact delta for the installed version with no network access. This is the strongest option for accuracy.
- The Dart SDK's `CHANGELOG.md` (dart-lang/sdk) and package CHANGELOGs on pub.dev are additional sources for per-package deltas (e.g., go_router, riverpod), which also cause stale-code issues. Not examined here.

### Gaps
- I did not verify the exact directory path of breaking-change Markdown in flutter/website, or whether a JSON/YAML index of breaking changes exists (I did not find one; the index appears to be HTML/Markdown only).
- I did not verify the fix_data YAML schema fields (e.g., `title`, `date`, `element`, `changes: kind: rename/addParameter…`) against the Dart data-driven fixes spec in this session. It is known from general Dart tooling knowledge but uncited here.
