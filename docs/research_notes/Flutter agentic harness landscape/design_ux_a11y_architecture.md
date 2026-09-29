# Design, UI/UX, Accessibility and Architecture Guidance for Flutter Agents (as of 2026-09-28)

Research date: 2026-09-28. About 25 tool calls (search + fetch). Where a page was read through a summarizing fetch tool, exact numbers were checked where possible. Claims based on training knowledge and not re-verified in this session are marked **[unverified]** and kept to Inferences/Gaps.

---

## 1. Design systems in Flutter 2025–2026 (Material 3, M3 Expressive, Cupertino / Liquid Glass, decoupling, theming, adaptive)

### Takeaway
Material and Cupertino were split out of the framework into standalone packages, `material_ui` and `cupertino_ui` (1.0.0, August 2026; Flutter blog post 2026-09-09). Neither **Material 3 Expressive** nor **iOS 26 Liquid Glass** has an official Flutter implementation yet. The Flutter team says the work is "underway" in the new packages, but gives no date. Until then only community packages cover them. Base Material 3 (`ColorScheme.fromSeed`, `ThemeData`, `TextTheme`, `Theme.of`) is still the official theming path. Adaptive guidance says to decide layout from window size, not from device type.

### Cited Findings
**Decoupling (material_ui / cupertino_ui)**
- The Material and Cupertino libraries are now standalone packages, `pkg:material_ui` and `pkg:cupertino_ui`, both at version 1.0.0. The blog post is dated 2026-09-09. — [Flutter Blog: Material and Cupertino decoupling are here](https://flutter.dev/blog/decoupling-material-cupertino)
- The packages "can now be released on their own weekly schedules" instead of following Flutter's roughly 3-month SDK cycle. The plan ends with "deprecation and eventual removal of the Material and Cupertino libraries from the Flutter framework itself", but no deprecation or removal dates are given. — [Flutter Blog](https://flutter.dev/blog/decoupling-material-cupertino)
- The team will also fill gaps in the core `widgets` library so it is "a stronger foundation" for other design languages (`macos_ui`, `fluent_ui`, shadcn-style systems). — [Flutter Blog](https://flutter.dev/blog/decoupling-material-cupertino)
- A migration guide exists: `dart fix` adds `material_ui` / `cupertino_ui` 1.0.0 to pubspec and rewrites the `package:flutter/material.dart` / `cupertino.dart` imports. Developers can opt in from Flutter 3.47. The packages were released as 1.0.0 around 2026-08-13 (this date comes from a search-result summary). — [docs.flutter.dev breaking change: material_ui and cupertino_ui](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui)
- Tracking issues: [flutter/flutter#163400 (Decouple Material and Cupertino)](https://github.com/flutter/flutter/issues/163400) and [#101479 (Move material and cupertino outside of Flutter)](https://github.com/flutter/flutter/issues/101479).

**Material 3 Expressive**
- The umbrella issue [flutter/flutter#168813](https://github.com/flutter/flutter/issues/168813) has three team statements. 2025-05-14: "not actively developing Material 3 Expressive… not accepting contributions". 2025-06-10: the team needs to "reconsider the long-term architecture for design system integration". 2025-07-29: new M3E work will happen in the decoupled packages. The issue has no update dated 2026.
- The 2026-09-09 blog says "work is already underway on official implementations of Liquid Glass and Material 3 Expressive". It gives no timeline. — [Flutter Blog](https://flutter.dev/blog/decoupling-material-cupertino)
- The docs.flutter.dev Material page and m3.material.io's Flutter page (search snippet) say "M3 Expressive is not available on Flutter". — [Material Design for Flutter](https://docs.flutter.dev/ui/design/material); [m3.material.io/develop/flutter](https://m3.material.io/develop/flutter)
- Community package `material_3_expressive` provides M3E* widgets with spring press feedback, shape morphing, state layers and an `M3ETheme` token object. It is unofficial. — [pub.dev material_3_expressive](https://pub.dev/packages/material_3_expressive); [GitHub paadevelopments/material_3_expressive](https://github.com/paadevelopments/material_3_expressive)

**Cupertino / iOS 26 Liquid Glass**
- Issue [flutter/flutter#170310](https://github.com/flutter/flutter/issues/170310) says Flutter is not developing the Apple '26 design features in the Cupertino library and is not accepting contributions. New iOS 26 work will go into the new packages in flutter/packages (search snippet).
- iOS 26 with Liquid Glass shipped on 2025-09-15. Flutter's Cupertino widgets still render the older look. — [Medium, Simra Husain, May 2026 (opinion piece)](https://medium.com/@simra.cse/flutter-wont-ship-liquid-glass-support-your-ios-26-app-is-stuck-in-2024-40a26af9b8fc)
- Community workarounds:
  - [cupertino_liquid_glass](https://pub.dev/packages/cupertino_liquid_glass): BackdropFilter-based imitation.
  - [cupertino_native_better](https://pub.dev/packages/cupertino_native_better): real native UIViews through hybrid composition.
  - [adaptive_platform_ui](https://pub.dev/packages/adaptive_platform_ui): native Liquid Glass on iOS 26+, Cupertino on older iOS, Material on Android.

**Theming (official cookbook, page updated 2026-08-24)**
- The official pattern is `ThemeData(colorScheme: ColorScheme.fromSeed(seedColor:, brightness:), textTheme: TextTheme(...))` on `MaterialApp`.
- Read values with `Theme.of(context).colorScheme.*` / `.textTheme.*`.
- To override locally, prefer `Theme.of(context).copyWith(...)` over a new `ThemeData`.
- Precedence: widget-specific style, then the nearest parent Theme, then the app theme. The cookbook uses `google_fonts`.
- Source: [Flutter cookbook: Use themes to share colors and font styles](https://docs.flutter.dev/cookbook/design/themes)
- The cookbook does **not** discuss ThemeExtension or design tokens (as extracted by the fetch). — same source

**Adaptive/responsive (official best practices)**
- Recommended practices:
  - Break widgets down into small pieces.
  - Design to the strengths of each form factor.
  - "Solve touch first".
  - **Don't lock orientation**. It is an accessibility issue, and Android large-screen guidelines expect both orientations.
  - Don't switch layout on `OrientationBuilder`. Use `MediaQuery.sizeOf` / `LayoutBuilder` with **Material window size classes** as breakpoints.
  - Don't take up all the horizontal space.
  - **Don't check hardware type** (`Platform.isAndroid`, devicePixelRatio as a stand-in for "tablet").
  - Support touch, mouse/trackpad (hover, right-click) and keyboard.
  - Restore scroll state with `PageStorageKey`.
  - Keep state across rotation, resize, fold and multi-window.
- Source: [docs.flutter.dev/ui/adaptive-responsive/best-practices](https://docs.flutter.dev/ui/adaptive-responsive/best-practices)
- Sub-pages: general approach, SafeArea & MediaQuery, large screens & foldables, user input & accessibility, capabilities & policies, automatic platform adaptations. — same source

### Inferences
- FlutterCraft's design-system skill should be **package-aware**. New projects in late 2026 should probably import `material_ui` / `cupertino_ui` rather than `flutter/material.dart`. Treat this as a moving target: the packages ship weekly and the deprecation dates are unknown.
- For M3E or Liquid Glass, the harness should tell agents clearly that no official implementation exists yet. Using a community package should be an explicit user choice (it is a dependency risk), not something the agent picks silently.
- ThemeExtension, `ColorScheme.fromSeed`'s `dynamicSchemeVariant`, component themes (`FilledButtonThemeData`, etc.) and `useMaterial3` being the default since Flutter 3.16 are established APIs **[unverified this session]**. The official cookbook does not teach them, so this is a real gap a FlutterCraft theming/design-token skill could fill. Suggested pattern: tokens as a `ThemeExtension<AppTokens>` covering spacing, radii and semantic colors, with `lerp`/`copyWith`, read through a `context.tokens` extension, plus a lint that bans raw `Color(0x...)`, `Colors.*` and magic numbers in `build` methods.
- The adaptive "don'ts" can be checked deterministically with a lint or grep: `setPreferredOrientations`, `Platform.isX` used in layout code, `OrientationBuilder`, `MediaQuery.of(context).size` instead of `sizeOf`.

### Gaps
- No official date for M3 Expressive or Liquid Glass in `material_ui` / `cupertino_ui`.
- I did not confirm the exact Flutter version where in-framework `material.dart` gets deprecated.
- I did not verify a Google I/O 2026 statement on M3 Expressive. The hamen skill (section 7) claims to cover "Google I/O 2026 updates (Expressive layouts, spacing system…)", but that is for Compose.
- I found no official Flutter design-token guidance (DTCG/Figma token pipelines into ThemeData).

---

## 2. Official Flutter app architecture guidance (docs.flutter.dev/app-architecture)

### Takeaway
Flutter officially recommends: a UI layer (Views + ViewModels, i.e. MVVM) and a data layer (Repositories + Services); an optional domain layer; unidirectional data flow; immutable models; Commands for UI events; dependency injection (provider); abstract repositories; and fakes for testing. The Compass app is the reference implementation. `flutter/agent-plugins` already packages this as a skill.

### Cited Findings
Source for all rows: [docs.flutter.dev/app-architecture/recommendations](https://docs.flutter.dev/app-architecture/recommendations)

| Area | Recommendation | Strength |
|---|---|---|
| Separation of concerns | Clearly defined data and UI layers | Strongly recommend |
| Separation of concerns | Repository pattern in the data layer | Strongly recommend |
| Separation of concerns | ViewModels + Views (MVVM) in the UI layer | Strongly recommend |
| Separation of concerns | "Do not put logic in widgets" | Strongly recommend |
| Separation of concerns | `ChangeNotifier` / `Listenable` for widget updates | Conditional |
| Separation of concerns | Domain layer (only for very complex or repeated logic) | Conditional |
| Handling data | Unidirectional data flow | Strongly recommend |
| Handling data | Immutable data models | Strongly recommend |
| Handling data | `Commands` for user-interaction events | Recommend |
| Handling data | freezed / built_value for immutable models | Recommend |
| Handling data | Separate API models and domain models | Conditional |
| App structure | Dependency injection (with `provider`) | Strongly recommend |
| App structure | Abstract repository classes | Strongly recommend |
| App structure | `go_router` | Recommend |
| App structure | Standard naming (`HomeViewModel`, `HomeScreen`, `UserRepository`, `ClientApiService`) | Recommend |
| Testing | Test components separately and together | Strongly recommend |
| Testing | Write fakes (and code that works with fakes) | Strongly recommend |

- Testing detail: unit tests for every service, repository and ViewModel; widget tests for views, routing and DI.
- Reference resources: the [Compass app](https://github.com/flutter/samples/tree/main/compass_app), very_good_cli, Very Good Engineering architecture docs, DevTools, flutter_lints. — same source
- The `flutter/agent-plugins` skill `flutter-apply-architecture-best-practices` "Architects Flutter applications using recommended layered approach (UI, Logic, Data)". — [github.com/flutter/agent-plugins](https://github.com/flutter/agent-plugins)

### Inferences
- Several of these rules are **structurally checkable** with an analyzer plugin (section 6) or a simple import-graph check:
  - Views must not import services or repositories directly.
  - ViewModels must not import `material_ui` / `material.dart` widgets.
  - Repositories should be abstract with concrete implementations.
  - Naming suffixes follow the convention.
  - Models are immutable (`@immutable`, freezed, final fields).
- "No logic in widgets" needs AI judgment, though DCM widget metrics can approximate it (section 6).
- The `Result` type and `Command` class come from the Compass app / architecture case study pages, not a published package **[unverified this session; I did not fetch the case-study pages]**. The harness would need to scaffold or vendor them.

### Gaps
- I did not fetch the architecture case-study pages (`/app-architecture/case-study`, `/design-patterns/result`, `/design-patterns/command`), so the exact Result/Command API shapes and the "optimistic state"/"offline-first" pattern pages are unconfirmed here.
- I did not confirm whether the official guidance changed its state-management stance in 2026 (provider versus Riverpod/Bloc). The recommendations page still names `provider`.

---

## 3. Accessibility automation in Flutter

### Takeaway
`flutter_test` has four built-in guideline matchers: Android 48×48 tap targets, iOS 44×44 tap targets, labeled tap targets, and text contrast (plus an AAA contrast variant). They are cheap, deterministic CI gates, but they cover only a small slice of WCAG. For runtime checks there is the `accessibility_tools` overlay, and the official **Flutter a11y agent** (Google Antigravity) does AI-driven audit and fix. Screen-reader flow, focus order, label meaning, and scaling/reflow at high text scale still need manual or AI review.

### Cited Findings
- The official testing page shows usage: `tester.ensureSemantics()`, then `await expectLater(tester, meetsGuideline(androidTapTargetGuideline))`, the same for `iOSTapTargetGuideline`, `labeledTapTargetGuideline` and `textContrastGuideline`, then `handle.dispose()`. — [docs.flutter.dev accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)

| Guideline | Check |
|---|---|
| `androidTapTargetGuideline` | 48×48 minimum |
| `iOSTapTargetGuideline` | 44×44 minimum |
| `labeledTapTargetGuideline` | Tap and long-press targets must have labels |
| `textContrastGuideline` | Text contrast (see below) |

  Source: [docs.flutter.dev accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)
- `MinimumTextContrastGuideline` "verifies that all nodes that contribute semantics via text meet minimum contrast levels".
  - It has separate constants `kMinimumRatioNormalText` and `kMinimumRatioLargeText`.
  - Large text is text at or above `kLargeTextMinimumSize`, or bold text at or above `kBoldTextMinimumSize`.
  - There is a stricter `MinimumTextContrastGuidelineAAA`.
  - Source: [api.flutter.dev MinimumTextContrastGuideline](https://api.flutter.dev/flutter/flutter_test/MinimumTextContrastGuideline-class.html)
  - The fetched excerpt did not show the numeric values. The docs page summary said "3:1 for 18pt+ text". The standard values are WCAG AA 4.5:1 for normal text and 3:1 for large text **[4.5 value unverified this session]**.
- Manual tools the docs recommend:
  - Android: Accessibility Scanner.
  - iOS: Xcode Accessibility Inspector, including its **Audit** function.
  - Web: `flutter run -d chrome --profile --dart-define=FLUTTER_WEB_DEBUG_SHOW_SEMANTICS=true`, then check ARIA in Chrome DevTools.
  - Standards referenced: WCAG 2, EN 301 549, VPAT.
  - Source: [docs.flutter.dev accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)
- **Official Flutter Accessibility Agent (`a11y`)** runs on Google Antigravity. It inspects semantic labels, validates touch targets (48×48 logical px), checks contrast and visuals, and applies automated code fixes such as Semantics wrapping. It is invoked as `@flutter_a11y_agent Audit this screen for accessibility issues.` — [docs.flutter.dev/ai/tools (updated 2026-09-14)](https://docs.flutter.dev/ai/tools)
- Secondary coverage of I/O 2026 (Flutter 3.44 / Dart 3.12) also mentions the a11y agent, and adds that Flutter web now respects reduced motion. — [Medium, Anand Gaur: Google I/O 2026 for Flutter Developers](https://medium.com/@anandgaur2207/google-i-o-2026-for-flutter-developers-998e87839cf2) (secondary)
- `accessibility_tools` (Rebel App Studio, MIT, v1.x) is an in-app overlay. Its checkers can be toggled: `minimumTapAreas`, `checkSemanticLabels`, `checkFontOverflows`, `checkImageLabels`. It also has a testing-tools panel for simulating conditions such as text scale. — [pub.dev accessibility_tools](https://pub.dev/packages/accessibility_tools)
- `flutter_accessibility_scanner` also exists on pub.dev. I did not evaluate it. — [pub.dev flutter_accessibility_scanner](https://pub.dev/packages/flutter_accessibility_scanner)

### Inferences
- **Deterministic tier (CI-gateable):**
  - The four `meetsGuideline` checks, run for every screen in light **and** dark theme, at textScaler 1.0 and at 2.0 or higher, and under LTR and RTL.
  - Custom guidelines: `AccessibilityGuideline` can be subclassed **[API existence from training knowledge; unverified]** to add rules such as "every `Image` has a semanticLabel or is excluded" or "no `GestureDetector` without Semantics".
  - Overflow detection at large text scale (catch `FlutterError` for RenderFlex overflow in widget tests).
  - Semantics-tree snapshot assertions with `find.bySemanticsLabel` / `SemanticsTester`-style matchers **[SemanticsTester is a framework-internal test helper; the public route is `tester.getSemantics` / `matchesSemantics`; unverified this session]**.
  - Lint bans on `setPreferredOrientations` and on hardcoded `fontSize` that ignores textScaler.
- **AI-judgment tier:**
  - Label quality and meaning.
  - Logical reading and focus order.
  - Whether decorative elements are excluded.
  - Error-message clarity and announcements.
  - Colour-only information.
  - Motion sensitivity.
  - Whether a flow can actually be completed with TalkBack/VoiceOver. Only a human or device automation can truly verify this.
- The official a11y agent is **Antigravity-only**. A cross-agent a11y reviewer that works with Claude Code, Codex and Gemini CLI, and combines `meetsGuideline` test generation with an AI review rubric, is a real gap FlutterCraft could fill.
- WCAG mapping (inference, typical):

| WCAG criterion | Flutter check |
|---|---|
| 1.4.3 Contrast (AA) | `textContrastGuideline` |
| 1.4.6 Contrast (AAA) | AAA variant |
| 2.5.5 / 2.5.8 Target Size | tap-target guidelines |
| 4.1.2 Name, Role, Value | labeled tap target (partial) |
| 1.4.4 Resize Text / 1.4.10 Reflow | overflow tests at high textScaler |
| 1.3.4 Orientation | no orientation lock |
| 1.4.11 Non-text contrast (icons, borders, focus rings) | **no** built-in guideline |

### Gaps
- I did not confirm the exact numeric ratios in the current `MinimumTextContrastGuideline` or the limits of its algorithm (it samples screenshot pixels, so behaviour with gradients or images is unclear).
- I found no documentation on whether the Antigravity a11y agent's rules or prompts are published or portable to other agent CLIs.
- I did not check the status of the `SemanticsRole` / ARIA-role work.

---

## 4. Visual verification: how agents can "see" the UI

### Takeaway
Agents now have several ways to see what they built:
1. **Official Dart/Flutter MCP server**: runtime errors, widget inspector, hot reload, and (per a secondary source) screenshots of a running app.
2. **Marionette MCP** (LeanCode): Playwright-like tap, type, scroll and screenshot.
3. **Widget Previewer**: stable in Flutter 3.47, driven by the `@Preview` annotation.
4. **Golden tests**: `matchesGoldenFile`, and alchemist for CI-stable goldens.
5. **integration_test / Patrol**: end-to-end flows.

The strongest loop is: build, hot reload, screenshot, AI critique, then freeze the approved state into golden and integration tests.

### Cited Findings
- **Dart & Flutter MCP server**, configured as `{"command":"dart","args":["mcp-server"]}`. — [docs.flutter.dev/ai/mcp-server](https://docs.flutter.dev/ai/mcp-server)
  - Default tools: `analyze_files`, `lsp`, `dtd` (connect to running apps), `vm_service`, `get_runtime_errors`, `hot_reload`, `hot_restart`, `widget_inspector`, `flutter_driver_command`, `pub`, `pub_dev_search`, `read_package_uris`, `rip_grep_packages`, `roots`, `get_active_location`.
  - Disabled/experimental tools: `create_project`, `dart_fix`, `dart_format`, `launch_app`, `list_devices`, `list_running_apps`, `get_app_logs`, `run_tests`, `stop_app`.
  - Requires Dart ≥3.9.0-163.0.dev. Flutter apps must run in debug or profile mode.
  - Source for these three bullets: [dart-lang/ai dart_mcp_server README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
- Screenshot capability: a secondary source says Dart 3.12 (I/O 2026) exposes `take_screenshot` in a "Runtime" group. It quotes "connect to a running app over DTD, list widgets, inspect state, take a screenshot of the render tree", which works "as long as `flutter run` is alive". — [startdebugging.net, May 2026](https://startdebugging.net/2026/05/dart-flutter-mcp-server-claude-code-cursor/)
  - **Conflict/uncertainty:** the README summary I fetched does not list a separately named screenshot tool (it may sit inside `widget_inspector`). The official docs page lists "runtime inspection" but no screenshot tool.
- **Official Flutter AI tooling** (page updated 2026-09-14): agent skills from `flutter/agent-plugins` and `dart-lang/skills`; the MCP server; Google's Developer Knowledge MCP (docs search); **package skills** bundled in pub.dev packages (`dart run skills@ get`); the a11y agent; and agent rules in `flutter/agent-plugins/rules`. — [docs.flutter.dev/ai/tools](https://docs.flutter.dev/ai/tools)
- **Marionette MCP** (LeanCode, the team behind Patrol, about 467 stars): "Playwright MCP… but for Flutter apps".
  - Tools: `get_interactive_elements`, tap / double / long-press / secondary tap, swipe, pinch, scroll, text entry, screenshots, logs, hot reload, back, and custom extensions.
  - Requires adding `marionette_flutter` and a `MarionetteBinding` in `main.dart` (debug only).
  - Non-Material design systems need extra configuration.
  - Source: [github.com/leancodepl/marionette_mcp](https://github.com/leancodepl/marionette_mcp)
- Other community runtime MCPs:
  - [bogachenko/flutter-ui-mcp](https://github.com/bogachenko/flutter-ui-mcp) (inspect, tap, screenshot).
  - [madalolito22/flutter_vm_mcp](https://github.com/madalolito22/flutter_vm_mcp) (real widget geometry over the VM service, "instead of guessing coordinates from a screenshot").
- The official skill `flutter-add-integration-test` "converts MCP actions into permanent integration tests". — [flutter/agent-plugins](https://github.com/flutter/agent-plugins); [SKILL.md](https://github.com/flutter/agent-plugins/blob/main/skills/flutter-add-integration-test/SKILL.md)
- **Widget Previewer** is **stable as of Flutter 3.47**. It runs in Android Studio, IntelliJ, VS Code, or a browser (`flutter widget-preview start`).
  - `@Preview(name, group, size, textScaleFactor, brightness, wrapper, theme, localizations)`. You can stack annotations, use `MultiPreview`, or define custom subclasses of `Preview`.
  - Limitations: rendered on web, so no `dart:io` / `dart:ffi` or native plugins; assets need package paths; unconstrained widgets are auto-constrained.
  - The docs do not mention agents or MCP.
  - Source: [docs.flutter.dev/tools/widget-previewer](https://docs.flutter.dev/tools/widget-previewer)
  - The official skill `flutter-add-widget-preview` exists. — [flutter/agent-plugins](https://github.com/flutter/agent-plugins)
- **Alchemist** (Betterment + VGV):
  - Two kinds of golden: *platform* goldens (real fonts, run locally) and *CI* goldens that render text as Ahem squares, so they are "platform agnostic" and "guaranteed to pass on CI".
  - Files live in `goldens/ci/` and `goldens/`.
  - Source: [github.com/Betterment/alchemist](https://github.com/Betterment/alchemist); [VGV tutorial](https://verygood.ventures/blog/alchemist-golden-tests-tutorial/)

### Inferences
- **Proposed agent visual loop for FlutterCraft:**
  1. The agent writes UI plus `@Preview`s. Each preview is parameterised over light/dark, textScale 1.0/2.0 and LTR/RTL.
  2. The harness renders the previews **headlessly as goldens** in `flutter test`, and the agent reads the PNGs. This works for Claude Code, Codex and Gemini: no device, fully deterministic.
  3. For flows, launch the app (desktop or web target is fastest on a dev machine). Drive it through Dart MCP or Marionette, take screenshots, and have the model critique them against a rubric.
  4. Once approved, freeze the result as alchemist CI goldens plus integration/Patrol tests, and gate CI on them.
- Golden diffs are deterministic, but they only detect **change**, not **quality**. Quality needs an AI or human review of the images.
- Previews cannot use native plugins, so the architecture needs fakes injected at the View/ViewModel boundary (consistent with section 2). This makes "previewable" a useful architectural fitness test.
- On Windows (FlutterCraft's dev environment), Flutter desktop plus the MCP screenshot path avoids emulator overhead **[inference]**.

### Gaps
- The exact name and status of the official screenshot tool in `dart_mcp_server` (Sept 2026) is unconfirmed. The README summary and the secondary blog differ.
- I did not fetch Patrol's current version, its MCP/agent features, or `integration_test` `takeScreenshot` specifics. I also did not check whether the widget previewer exposes an API or CLI to export PNGs for agents.
- I found no published benchmark of how well LLMs critique Flutter screenshots.

---

## 5. UI/UX quality heuristics that can be encoded for agents

### Takeaway
Official Flutter sources give encodable rules for adaptivity, touch targets, contrast, orientation and input. General UX heuristics (Nielsen), HIG and Material rules have to be put into a rubric by the harness. They split into lint-checkable and test-checkable rules versus rules that need judgment.

### Cited Findings
- Touch targets: 48×48 on Android and 44×44 on iOS, enforced by flutter_test guidelines. — [docs.flutter.dev accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)
- Breakpoints: use Material **window size classes**. Build layouts with `LayoutBuilder` / `MediaQuery.sizeOf`. Don't fill all the horizontal space on large screens. — [docs.flutter.dev adaptive best practices](https://docs.flutter.dev/ui/adaptive-responsive/best-practices)
- Input: support touch, mouse (hover, right-click) and keyboard. Treat keyboard and mouse as accelerators on top of touch. — same source
- Localization is already covered by an official skill (`flutter-setup-localization`: `flutter_localizations` + `intl` + l10n config). — [flutter/agent-plugins](https://github.com/flutter/agent-plugins)
- Dark mode: set up with `ColorScheme.fromSeed(brightness: Brightness.dark)`. — [Flutter cookbook themes](https://docs.flutter.dev/cookbook/design/themes)
- Widget previews support `brightness`, `textScaleFactor` and `localizations` per preview, so the variant matrix can be seen directly. — [docs.flutter.dev/tools/widget-previewer](https://docs.flutter.dev/tools/widget-previewer)
- The official agent-plugins skill list has **no** theming, design-system, UX-state or accessibility skill. Its ten skills are: integration test, widget preview, widget test, architecture, responsive layout, fix layout issues, JSON serialization, declarative routing, localization, http. — [flutter/agent-plugins](https://github.com/flutter/agent-plugins)

### Inferences
Proposed encoding:

| Heuristic | Deterministic check | Needs AI/human |
|---|---|---|
| Touch targets ≥48/44 | `meetsGuideline` | – |
| Text contrast AA | `meetsGuideline(textContrastGuideline)` in light and dark | Non-text contrast, focus rings |
| Text scaling | Widget test at textScaler 2.0+ with no overflow errors; lint bans hardcoded TextStyle sizes outside the theme | Whether the layout still reads well |
| Typography scale | Lint: only `Theme.of(context).textTheme.*` or tokens; no inline `fontSize:` | Hierarchy and choice of type roles |
| Spacing system | Lint: EdgeInsets and SizedBox values from the token set (e.g. 4/8 multiples) | Visual rhythm and density |
| Color usage | Lint: no `Color(0x…)` or `Colors.*` in `lib/ui/**` | Semantic correctness of colour roles |
| Loading/empty/error states | ViewModel state-type exhaustiveness (sealed class or Result + switch); a test per state | Copy quality, recovery paths |
| Dark mode | Goldens in both brightnesses | Aesthetic quality |
| RTL | Goldens and tests with `Directionality.rtl`; lint prefers `EdgeInsetsDirectional` / `AlignmentDirectional` | Icon mirroring appropriateness |
| Localization | No hardcoded user-facing strings (analyzer rule), ARB completeness | Translation quality, text expansion |
| Orientation/adaptive | Lint bans `setPreferredOrientations`, `Platform.isX` in UI, `OrientationBuilder` | Form-factor-appropriate design |
| Nielsen: visibility of system status, error prevention and recovery, consistency | Partly (loading indicators exist, destructive actions have confirmations) | Mostly |
| HIG/Material conformance | Widget-type checks (e.g. Cupertino on iOS when adaptive is requested) | Mostly |

- The "loading/empty/error" state rule lines up with the official Command/Result pattern: a Command exposes running / error / completed, so a check can require every View bound to a Command to render all three **[inference; Command API not re-verified]**.

### Gaps
- I found no official Flutter documentation that maps Nielsen heuristics or HIG to Flutter rules. Any rubric would be FlutterCraft-authored.
- I did not fetch M3 spacing, type-scale or window-size-class breakpoint values (commonly 600/840/1200/1600 dp) from m3.material.io **[unverified]**.

---

## 6. Lints and static analysis for design/architecture enforcement

### Takeaway
Dart 3.10 added a first-party **analyzer plugin system** (`analysis_server_plugin`). It replaces the now-archived `custom_lint`, and its diagnostics show in the IDE and in `dart analyze`. It is the right vehicle for FlutterCraft's own architecture and design-token rules. DCM (commercial, 530+ rules, widget metrics) is the richest off-the-shelf option. `flutter_lints` is the official baseline. `very_good_analysis` is a stricter community preset.

### Cited Findings
- Analyzer plugins allow custom lints, warnings and quick fixes. Support was added in **Dart 3.10**. Plugin warnings are on by default; plugin lints are off by default and must be enabled under the plugin's `diagnostics`. Plugins are declared in a top-level `plugins:` section of `analysis_options.yaml`. — [dart.dev/tools/analyzer-plugins](https://dart.dev/tools/analyzer-plugins)
- `custom_lint` is archived and `analysis_server_plugin` is the recommended replacement. Migration guides: [LeanCode: Migrate to the new Dart analyzer plugin system](https://leancode.co/blog/migrating-to-dart-analyzer-plugin-system); [VGV: Creating your first Dart analyzer plugin](https://verygood.ventures/blog/creating-your-first-dart-analyzer-plugin-with-the-new-plugin-system/); [sdk using_plugins.md](https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server_plugin/doc/using_plugins.md)
- Example of an ecosystem migration in Sept 2026: `dartway_lints` is now an analyzer plugin (`plugins: dartway_lints: ^0.4.0`), with results "shown in the IDE and in `dart analyze`". — [dartway PR #304](https://github.com/dartway/dartway/pull/304)
- Per-rule configuration options in analysis options are being added to the SDK (in progress). — [dart-lang/sdk PR #63099](https://github.com/dart-lang/sdk/pull/63099)
- DCM has 530+ configurable rules and an `analyze-widgets` command (widget quality, usages, duplication, a combined complexity score, and maximum widget nesting depth in `build`). It can output JSON. — [dcm.dev](https://dcm.dev/); [DCM analyze](https://dcm.dev/features/analyze/); [DCM metrics](https://dcm.dev/docs/metrics); [DCM blog, 2025-10-21](https://dcm.dev/blog/2025/10/21/getting-started-flutter-static-analytics-lints/)
- The official architecture recommendations point to `flutter_lints` as the recommended lint package. — [docs.flutter.dev/app-architecture/recommendations](https://docs.flutter.dev/app-architecture/recommendations)

### Inferences
- **What each tool can enforce:**
  - *flutter_lints / very_good_analysis:* hygiene rules (const constructors, `use_build_context_synchronously`, `avoid_print`, etc.). They are not design-aware.
  - *Analyzer plugin (FlutterCraft-authored):*
    - Layer import rules (View must not import a repository or service).
    - A token-only rule (no raw colours, font sizes or EdgeInsets literals in the UI layer).
    - Banned adaptive anti-patterns.
    - Images must have a semantic label.
    - `GestureDetector` / `InkWell` must have Semantics or a tooltip.
    - Prefer `EdgeInsetsDirectional`.
    - No hardcoded strings in `Text()`.
    - Quick fixes let agents auto-remediate.
  - *DCM:* widget complexity and nesting metrics as a proxy for "logic in widgets" and "break down your widgets". Metrics and JSON output are useful for agent feedback. It is commercial and needs a licence.
- Because plugin lints show up in `dart analyze`, and the Dart MCP server's `analyze_files` surfaces analyzer diagnostics, custom FlutterCraft rules would reach **every** agent automatically through the MCP server with no per-agent integration **[inference; I assume plugin diagnostics appear in MCP `analyze_files`, which is not verified]**.

### Gaps
- I did not verify the current `very_good_analysis` version or rule count, or DCM's 2026 pricing and free tier.
- I did not confirm whether the MCP `analyze_files` tool includes analyzer-plugin diagnostics.

---

## 7. Existing agent skills/rules packs for Flutter UI/UX and design quality

### Takeaway
The official packs are `flutter/agent-plugins` (10 skills plus rules), `dart-lang/skills`, pub.dev package skills, and the Antigravity a11y agent. They cover architecture, layout, testing, routing and l10n, but **not** theming/design systems or UX quality. Their only accessibility coverage is the Antigravity-only a11y agent. Community skills exist but are mostly generic prose guides of uneven quality. The best-known one (hamen/material-3-skill, about 1.4k stars) is Compose-first.

### Cited Findings
- `flutter/agent-plugins` has ten skills: `flutter-add-integration-test`, `flutter-add-widget-preview`, `flutter-add-widget-test`, `flutter-apply-architecture-best-practices`, `flutter-build-responsive-layout`, `flutter-fix-layout-issues`, `flutter-implement-json-serialization`, `flutter-setup-declarative-routing`, `flutter-setup-localization`, `flutter-use-http-package`.
  - It also has a `/rules` directory and plugin manifests for `.agents`, `.claude-plugin`, `.codex-plugin` and `.cursor-plugin`.
  - Install with `npx skills@1.5.17 add flutter/agent-plugins --skill '*' --agent universal --yes` (install command from search snippet).
  - Source: [github.com/flutter/agent-plugins](https://github.com/flutter/agent-plugins)
- `dart-lang/skills` covers unit tests, dependency resolution and static-analysis remediation. Package skills ship inside pub.dev packages (`dart run skills@ get`). — [docs.flutter.dev/ai/tools](https://docs.flutter.dev/ai/tools)
- [kevmoo/dash_skills](https://github.com/kevmoo/dash_skills) holds Dart/Flutter ecosystem agent skills from a Dart team member. I did not evaluate its contents.
- **hamen/material-3-skill** (about 1.4k stars, v1.1.1 on 2026-06-29):
  - 30+ M3 components, tokens, theming, dynamic colour, responsive/foldables, and "Google I/O 2026 updates (Expressive layouts, spacing system, watch/XR)".
  - Has a 10-category compliance audit: color tokens, typography, shape, elevation, components, layout, navigation, motion, accessibility, theming.
  - Primarily **Jetpack Compose**; Flutter support is secondary.
  - Source: [github.com/hamen/material-3-skill](https://github.com/hamen/material-3-skill)
- Other community skills:
  - `flutter-ui-design` on LobeHub (MD3 tokens, ThemeData/ThemeExtension, adaptive, accessible contrast and motion). — [LobeHub](https://lobehub.com/skills/neversight-learn-skills.dev-flutter-ui-design)
  - `material3` (Flutter-focused, `ColorScheme.fromSeed`). — [LobeHub](https://lobehub.com/skills/michaelkeevildown-claude-agents-skills-material3)
  - `flutter-ui-ux`. — [ajianaz/skills-collection](https://github.com/ajianaz/skills-collection/blob/main/skills/flutter-ui-ux/SKILL.md)
  - `flutter-control-and-screenshot` (rodydavis). — [explainx.ai listing](https://explainx.ai/skills/rodydavis/skills/flutter-control-and-screenshot)
  - `flutter-ux-theming`. — [skills.lc](https://skills.lc/garethbaumgart/money-tracker/garethbaumgart-money-tracker-skills-flutter-ux-theming-skill-md)
  - Descriptions come from marketplace snippets. I did not audit them.
- `ui-ux-pro-max` (installed locally in this environment) claims multi-stack UI/UX guidance including Flutter. It is general-purpose, not Flutter-specific (from the local skill description; not researched further).

### Inferences
- The user's gap analysis is **confirmed**. There is no official theming/design-system skill and no official UX-quality skill, and the official a11y agent is tied to Antigravity rather than portable across agents.
- Community skills are mostly static prose. None I found combines guidance with **deterministic verification** (generated `meetsGuideline` tests, golden matrices, custom analyzer rules). That combination is FlutterCraft's opportunity.
- Community skills that recommend M3 Expressive may point agents at unofficial packages. The harness should warn about this.

### Gaps
- I did not audit any community skill's content in depth for accuracy or staleness (for example, whether they still use `useMaterial3: true` boilerplate or the deprecated `MaterialStateProperty` instead of `WidgetStateProperty` **[unverified]**).
- I did not see the contents of the `flutter/agent-plugins/rules` files.
