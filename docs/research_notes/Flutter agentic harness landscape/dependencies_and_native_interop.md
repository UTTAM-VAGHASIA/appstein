# Flutter/Dart Package Dependency Risk and Plugin-Free Native Interop (as of 2026-09-28)

Scope: evidence for a FlutterCraft "dependency policy" for AI agents. The tentative policy under test is: (a) write small pure-Dart helpers in-house; (b) use well-maintained packages for complex platform features (camera, permissions, notifications, payments, maps, auth); (c) write native code only when no good package exists.

Overall verdict (inference, detailed per section): the evidence **mostly supports** the policy, with three amendments. (1) "Well-maintained" needs a concrete, machine-checkable definition, because the ecosystem is going through two forced native migrations in 2026 (SwiftPM on iOS, built-in Kotlin / AGP 9 on Android) that will strand unmigrated plugins. (2) Every package an agent proposes must be checked for existence and version before it goes into `pubspec.yaml`, because package hallucination is a documented, measurable risk. (3) "Write native code" should mean Pigeon plus platform channels, not raw string-keyed channels, and not jnigen/swiftgen as the default yet. jnigen is at 1.0, but swiftgen is still unstable and LLMs are documented to do poorly at it.

## 1. Package ecosystem health and reliable vetting signals

### Takeaway
pub.dev exposes three first-party signals: likes, pub points (automated quality checks by `pana`) and download counts. It also has verified-publisher badges and a curated, still-active Flutter Favorite list. None of these proves ongoing maintenance on its own. Even Google-published packages get discontinued (for example `flutter_markdown` in 2025), so vetting has to combine several signals, with recency and platform-migration status weighted heavily.

### Cited Findings
- pub.dev shows three metrics per package: **Likes** (user sentiment), **Pub Points** (quality), and **Download Count**. It notes that download counts are "not a direct user count due to caching" and are distorted by CI and local caching. — [pub.dev scoring help](https://pub.dev/help/scoring)
- Pub points cover: Dart file conventions (pubspec, LICENSE, README, CHANGELOG); documentation (at least 20% of the public API documented, plus an example); platform support (with **bonus points for Swift Package Manager support and WebAssembly readiness**); static analysis (standard lints, passes `dart analyze`/`flutter analyze`); and up-to-date dependencies (compatible with the latest stable Dart/Flutter SDK and dependency versions). Scoring is done by the `pana` tool, which authors can run locally. — [pub.dev scoring help](https://pub.dev/help/scoring)
- The older "popularity" metric now appears as a raw download count. The scoring page lists likes, pub points and downloads. (I did not find the exact date popularity was replaced, so treat this as inferred from the current page.) — [pub.dev scoring help](https://pub.dev/help/scoring)
- A **verified publisher** badge means pub.dev confirmed the publisher controls a DNS domain, using Google Search Console "Domain Property" verification. It is a one-time check: "Domain name ownership is verified only once when a publisher is created… Losing control of a domain does not cause the original publisher owner to lose access to the publisher." — [dart.dev verified publishers](https://dart.dev/tools/pub/verified-publishers)
- The **Flutter Favorite** program is still active (page last updated May 11, 2026). Packages are chosen by the Flutter Ecosystem Committee (currently Abdallah Shaban, Pooja Bhaumik, Hillel Coren, Majid Hajian, Simon Lightfoot, John Ryan, Diego Velasquez). The criteria are: overall pub.dev score, a permissive license, a GitHub tag matching the pub.dev version, feature completeness (not beta), **verified publisher**, usability, runtime behavior, and high-quality dependencies. The list lives at pub.dev/flutter/favorites. — [Flutter Favorite program](https://docs.flutter.dev/packages-and-plugins/favorites)
- **First-party packages get discontinued too.** Google marked `flutter_markdown` as discontinued on pub.dev (on 30 May 2025). The community fork `flutter_markdown_plus`, maintained by Foresight Mobile, is the successor. — [flutter/flutter #162966](https://github.com/flutter/flutter/issues/162966); [Foresight Mobile blog](https://foresightmobile.com/blog/flutter-markdown-plus-google-handover); [flutter_markdown_plus on pub.dev](https://pub.dev/packages/flutter_markdown_plus)
- The Flutter team's own architecture guide recommends a small set of third-party packages. `provider` for dependency injection is "Strongly recommend". `go_router` for navigation is "Recommend" ("the preferred way to write 90% of Flutter applications"). `freezed`/`built_value` for immutable models are "Recommend", with a caveat: "These code generation packages can add significant build time to your applications if you have a lot of models." `ChangeNotifier` (an SDK API, not a package) is "Conditional", and the guide says state-management choice "ultimately… comes down to personal preference." — [Flutter app architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- Community commentary calls abandoned dependencies "one of the most underestimated threats in the Flutter ecosystem", notes that 35,000+ packages existed on pub.dev (a 2024 figure), and recommends treating "last updated" as a caution signal, especially for plugins that wrap fast-moving platform APIs. This is an opinion piece with no measured data. — [Medium: "The Silent Killer of Flutter Apps: Abandoned Packages"](https://devharshmittal.medium.com/the-silent-killer-of-flutter-apps-abandoned-packages-9eb19b1f2606)
- Tools that detect unused dependencies exist (`dependency_validator`, `flutter_unused_packages`). — [pub.dev flutter_unused_packages](https://pub.dev/packages/flutter_unused_packages/versions)

### Inferences
- A defensible, machine-checkable vetting rubric for FlutterCraft agents could be:
  - **Hard blockers:** the package does not exist; it is marked discontinued on pub.dev; no release in over 12–18 months for a *plugin* (pure-Dart packages can tolerate longer); no SwiftPM support for an iOS plugin after Dec 2026; the plugin still applies KGP (not migrated to built-in Kotlin).
  - **Positive signals, in order:** `flutter.dev`/`dart.dev`/`google.dev` publisher, or Flutter Favorite; verified publisher of a real vendor (e.g., `firebase.google.com`, the Stripe or Google Maps SDK owner); high pub points (maxed platform plus SwiftPM bonus); a large, sustained download count; likes.
  - The thresholds (12–18 months, and so on) are my suggestion, not an official standard.
- A verified publisher badge proves identity at creation time, not maintenance or security. The harness should not treat it as a maintenance signal.
- The official architecture guide explicitly endorses a few packages (provider, go_router, freezed). It does not tell developers to avoid packages. This supports the "use packages where they add real value" half of the policy. The build-time caveat on codegen packages supports "prefer in-house pure Dart for small things" (for example, hand-writing `copyWith`/`==` for a few models instead of adding `freezed` to a small app).
- `flutter_markdown` shows that even a `flutter.dev` publisher does not guarantee longevity. The policy should always include a "discontinued / successor" check.

### Gaps
- I found no quantitative 2025–2026 study of what share of pub.dev packages are abandoned or unmaintained (for example, the percentage of the top 1,000 plugins without a release in 12 months). Only opinion pieces turned up.
- I did not retrieve the current Flutter Favorites list itself, only the program page.
- r/FlutterDev threads on dependency minimalism were not retrieved. Community sentiment is therefore represented only by blog posts.

## 2. How plugins cause native build conflicts (Kotlin/AGP/minSdk/namespace/CocoaPods/SPM)

### Takeaway
In 2026, native build breakage from plugins comes mainly from two platform migrations happening at once. On iOS, SwiftPM became the default in Flutter 3.44 and the CocoaPods trunk freezes on Dec 2, 2026; only 61% of the top 100 iOS plugins had migrated as of April 2026. On Android, AGP 9 dropped support for applying the Kotlin Gradle Plugin, so plugins must migrate to "built-in Kotlin". Every plugin a project depends on is exposed to both migrations. This is the strongest argument for keeping the plugin count low.

### Cited Findings
- As of **Flutter 3.44**, SwiftPM is the default for iOS/macOS native dependencies. The CocoaPods trunk becomes **permanently read-only on December 2, 2026**. "**61% of the top 100 iOS plugins have migrated**" (blog post dated **April 30, 2026**). Packages without SwiftPM support receive lower pub.dev scores. When a plugin lacks SwiftPM support, Flutter prints warnings. Developers are told to file issues, find alternative packages, or temporarily set `enable-swift-package-manager: false` in pubspec.yaml. — [Flutter blog: Saying goodbye to CocoaPods](https://flutter.dev/blog/saying-goodbye-to-cocoapods-swift-package-manager-is-soon-the-default-in-flutter)
- Flutter docs say plugins should support **both** SwiftPM and CocoaPods "until further notice". The Flutter team has been automatically opening GitHub issues on popular plugins asking them to add SwiftPM support. — [Flutter docs: SwiftPM for plugin authors](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors); [flutter/flutter #187485](https://github.com/flutter/flutter/issues/187485) (issue title "[SPM] Add Swift Package Manager support for iOS (and macOS)"; the automated-issue detail comes from the search summary and was not fully fetched)
- Real plugins still had open SwiftPM requests in 2026, for example `flutter_workmanager` (fluttercommunity), `flutter_js`, and a payments SDK (`fiuu_mobile_xdk_flutter`). — [flutter_workmanager #665](https://github.com/fluttercommunity/flutter_workmanager/issues/665); [flutter_js #190](https://github.com/abner/flutter_js/issues/190); [Fiuu issue #7](https://github.com/FiuuPayment/Mobile-XDK-Fiuu_Flutter/issues/7)
- **AGP 9.0 removed support for applying the Kotlin Gradle Plugin.** Flutter temporarily allows KGP while the ecosystem migrates, but will remove that allowance "when AGP 10.0 becomes the default". Plugin authors should require Flutter ≥3.44. Enabling `android.builtInKotlin=true` in an example app requires Flutter ≥3.47. — [Flutter docs: built-in Kotlin for plugin authors](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors); [for app developers](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)
- Many popular third-party plugins had open "migrate to built-in Kotlin / AGP 9" issues in 2026: `wakelock_plus` ("AGP 9 incompatibility — kotlin-android plugin must be removed"), `flutter_tts`, `flutter_jailbreak_detection`, `flutter_carplay` (mentions an "AGP 9 / Flutter 3.47+ KGP warning"), and vendor SDKs from Braze and Splunk. Even Flutter-maintained plugins needed an umbrella tracking issue. — [wakelock_plus #117](https://github.com/fluttercommunity/wakelock_plus/issues/117); [flutter_tts #646](https://github.com/dlutton/flutter_tts/issues/646); [braze #135](https://github.com/braze-inc/braze-flutter-sdk/issues/135); [splunk-otel-flutter #57](https://github.com/signalfx/splunk-otel-flutter/issues/57); [flutter_carplay #138](https://github.com/oguzhnatly/flutter_carplay/issues/138); [flutter/flutter #181383](https://github.com/flutter/flutter/issues/181383)

### Inferences
- Every native plugin carries two migration liabilities in 2026–2027 (SwiftPM, and built-in Kotlin/AGP 9–10). In practice, the harness's vetting check should include "Has this plugin migrated to SwiftPM, and does it avoid applying KGP?" Both can be checked from the pub.dev score (SwiftPM bonus) and from the plugin's `android/build.gradle`.
- This **supports** "pure-Dart in-house for small things". A pure-Dart package has no native build surface, so these migrations cannot break it. It also argues for preferring pure-Dart packages over plugins when both would work.
- It **nuances** "use packages for complex platform features". The package must be one that keeps pace with platform migrations, typically Flutter-team (`flutter.dev`), Firebase, or vendor-maintained. A stale community plugin for a small platform feature (wakelock, TTS, jailbreak detection) can be *worse* than a small in-house Pigeon wrapper.
- Older classic conflicts (minSdk bumps, missing `namespace` under AGP 8, Kotlin version mismatches) were not re-researched here. They are well known from 2023–2025, and the 2026 AGP 9 change is a continuation of the same kind of problem.

### Gaps
- I found no SwiftPM adoption figure after April 2026 (61% of the top 100). The number was likely higher by September 2026, but this is unverified.
- I found no numeric data on what fraction of top plugins had migrated to built-in Kotlin.

## 3. AI hallucination of packages ("slopsquatting") and of package APIs; pub.dev-specific evidence

### Takeaway
Package hallucination is a well-established, peer-reviewed risk. It occurs in at least 5.2% of commercial-model code samples and 21.7% of open-source-model samples, and the hallucinated names often repeat across runs, which makes them easy to register maliciously. I found **no Dart/pub.dev-specific study or documented slopsquatting incident**. The general mechanism clearly applies to pub, since anyone with a Google account can publish there.

### Cited Findings
- Spracklen et al., "We Have a Package for You! A Comprehensive Analysis of Package Hallucinations by Code Generating LLMs", **USENIX Security 2025**: 16 LLMs, 576,000 code samples in two languages (Python and JavaScript). The hallucination rate was "at least 5.2% for commercial models" and "21.7% for open-source models", with **205,474 unique hallucinated package names**. — [arXiv 2406.10279](https://arxiv.org/abs/2406.10279)
- Secondary summaries of that research report that about 20% of AI-generated code samples included hallucinated packages and that **58% of hallucinated names repeated across multiple runs**. This repeatability is what makes "slopsquatting" (registering the hallucinated name) a viable attack. — [Socket blog](https://socket.dev/blog/slopsquatting-how-ai-hallucinations-are-fueling-a-new-class-of-supply-chain-attacks); [Help Net Security](https://www.helpnetsecurity.com/2025/04/14/package-hallucination-slopsquatting-malicious-code/) (secondary; the 58% figure was not verified against the paper text)
- Follow-up 2026 arXiv work extends the problem to Rust crates, local coding LLMs, and inference-time defenses. One paper reports an unlearning method that "reduces hallucination rates by 88%". These are titles and snippets from search only, not read in full. — [Rust crates (arXiv 2606.08444)](https://arxiv.org/pdf/2606.08444); [local coding LLMs (arXiv 2608.23897)](https://arxiv.org/pdf/2608.23897); [inference-time defenses (arXiv 2608.22652)](https://arxiv.org/pdf/2608.22652); [LLM Ghostbusters (arXiv 2605.01047)](https://arxiv.org/html/2605.01047)
- A Flutter/Dart practitioner wrote in May 2026 that his jnigen/swiftgen article "was written after I got annoyed with the AI agent incorrect output when working on the migration". He hoped the article would "give future AI models a bit more native-interop content in their corpus". This is anecdotal but direct evidence of API-level hallucination in Dart native-interop code. — [Roszkowski, "jnigen and swiftgen in 2026"](https://roszkowski.dev/2026/swiftgen-jnigen/)
- Pub-side security: a search snippet reports a pub client bug in Dart SDK <3.11.0 / Flutter <3.41.0 where "a malicious package archive can have files extracted outside the destination directory in the PUB_CACHE" (path traversal). This comes from an aggregator and was not verified against the primary advisory. — [cvedetails: Dart](https://www.cvedetails.com/vulnerability-list/vendor_id-12360/Dart.html)

### Inferences
- The mechanism is ecosystem-agnostic, so pub.dev is exposed. It is probably less targeted than npm or PyPI simply because the ecosystem is smaller (inference). Dart's lower representation in training data plausibly *raises* the rate of hallucinated names and APIs relative to Python and JS, but no Dart measurement exists.
- **Supports the policy.** Writing small helpers in pure Dart removes the hallucination attack surface entirely for those helpers. For packages that are used, the harness should enforce existence and reputation checks before `flutter pub add`. Candidates are the Dart MCP server's `pub_dev_search`, or the pub.dev API (`https://pub.dev/api/packages/<name>`), combined with the vetting rubric in section 1.
- Because hallucinated names repeat, a local "known-good package allowlist" (Flutter Favorites plus `flutter.dev`/`dart.dev`/`google.dev`/`firebase.google.com` publishers plus a curated list) is an effective, cheap mitigation (inference).

### Gaps
- No Dart/pub.dev-specific package-hallucination measurement was found.
- No documented pub.dev slopsquatting or malicious-typosquat incident was found. Searches returned only npm/PyPI/RubyGems cases.
- I found no public information on whether pub.dev reserves names or blocks near-duplicates to prevent typosquatting.

## 4. Package API version drift and mitigations

### Takeaway
The Dart team has shipped first-party tooling aimed at this problem. **Skills CLI 1.0** (`dart run skills@ get`, announced Sep 8, 2026) installs agent skills that are bundled inside the package versions in your dependency tree. The **Dart and Flutter MCP server** gives agents `pub_dev_search`, `read_package_uris`, `rip_grep_packages` (grep across dependency sources in the pub cache), and `lsp` (hover, signatures, symbols), so agents can read the *installed* API instead of recalling it. Both are young. The MCP server is still labeled experimental, and skills adoption is limited to a few packages.

### Cited Findings
- "Package skills allow package authors to distribute standardized, context-rich AI agent instructions directly with their pub packages." Consumers run `dart run skills@ get` in the project root to discover and install skills from their dependencies, and `dart run skills@ remove` to remove them. A package's `skills/` directory is bundled automatically by `dart pub publish`. — [dart.dev: Package skills](https://dart.dev/ai/package-skills); [dart.dev: Ship skills with packages](https://dart.dev/tools/pub/package-skills); [pub.dev: skills](https://pub.dev/packages/skills)
- The Skills CLI 1.0 blog post is dated **September 8, 2026**. It says skills "bridge the knowledge cutoff gap, enabling agents to work more effectively on unfamiliar or updated codebases, dependencies, and tools". Named early adopters are Jaspr, Serverpod, Flutter Scene, and GenUI. The post mentions "package version support" as a goal but does not detail how skills track the resolved version. — [Dart blog: Skills CLI 1.0](https://dart.dev/blog/skills-cli-1-0-bundle-and-distribute-ai-agent-skills-for-your-packages)
- The PowerSync docs repo has an issue titled "Dart SDK bundles PowerSync Agent Skills with pub.dev releases", which shows third-party vendors adopting package-bundled skills. — [powersync-docs #664](https://github.com/powersync-ja/powersync-docs/issues/664)
- Dart MCP server tools include `pub_dev_search` ("Searches pub.dev for packages relevant to a given search query"), `pub` (runs pub commands), `read_package_uris` (reads files in package dependencies), `rip_grep_packages` (ripgrep over package dependencies), `lsp` (hover, signatures, symbol search), `analyze_files`, `dart_fix`, `run_tests`, `hot_reload`, `get_runtime_errors`, `widget_inspector`, and others. The status is "WIP. This package is still experimental and is likely to evolve quickly." It requires Dart SDK ≥3.9.0-163.0.dev. — [dart-lang/ai dart_mcp_server](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
- docs.flutter.dev describes the MCP server as giving assistants "real-time access to analyzer diagnostics, symbol resolution, test runners, and runtime inspection". — [docs.flutter.dev: MCP server](https://docs.flutter.dev/ai/mcp-server)
- The `jni` 1.0.0 release shows how drift happens in practice. It made significant breaking changes from 0.14/0.15: bindings config moved from YAML to a Dart script in `tool/`, `toDartString()` became `toString()`, and callbacks became setters. Generated constructor overload names also shift unpredictably ("Intent.new$2 can now be Intent.new$12"). Code recalled from the 0.x era is therefore wrong at 1.x. — [Roszkowski 2026](https://roszkowski.dev/2026/swiftgen-jnigen/)

### Inferences
- A robust harness mitigation stack, in rough order of reliability:
  1. Pin and read the installed version (`pubspec.lock`).
  2. Read the actual source or dartdoc from the pub cache (`read_package_uris` / `rip_grep_packages`, or the filesystem) before writing calls to the API.
  3. Install package skills (`dart run skills@ get`) where they exist.
  4. Close the loop with `analyze_files`/`dart analyze` after every edit, so wrong-version API calls surface as static errors immediately. Dart's strong static typing makes this loop unusually effective compared with dynamic languages (inference).
- **Supports the policy.** Every added package adds an API surface the agent can misremember. Pure-Dart helpers written in-house are fully visible in the repo.
- Skills coverage is thin as of September 2026 (a handful of packages), so FlutterCraft cannot rely on skills alone. The source-reading plus analyzer loop is the general mitigation.

### Gaps
- I found no measurement of how often LLMs write code for the wrong major version of Dart packages.
- It is unclear whether `dart run skills@ get` re-syncs skills automatically when a dependency is upgraded. The blog does not say.
- It is unclear whether Flutter-team packages (go_router, camera, etc.) ship skills yet. Not verified.

## 5. Plugin-free native interop: Pigeon, platform channels, dart:ffi, jnigen/JNI, ffigen/swiftgen, build hooks, and LLM skill at Kotlin/Swift

### Takeaway
As of September 2026, the production path is **Pigeon-generated platform channels**. The official docs present Pigeon as the type-safe alternative to raw channels. **Build hooks (native assets) are stable** (Dart 3.10 / Flutter 3.38). **`package:jni` reached 1.0**, so jnigen is usable. **swiftgen is still not stable** and requires `@objc`-compatible Swift. The Flutter team's stated long-term direction is direct synchronous interop via jnigen/ffigen, and a P1 Pigeon issue added FFI/JNI backends. I found no benchmark comparing LLM accuracy on Kotlin/Swift platform code with Dart, but there is anecdotal evidence that agents do poorly with native interop generators.

### Cited Findings
- The Flutter platform-channels page presents platform channels and **Pigeon** as the two ways to write platform-specific code. Pigeon "eliminates the need to match strings between host and client for the names and data types of messages… The generated code is readable and guarantees there are no conflicts between multiple clients of different versions." The page does not mention FFI, jnigen, or ffigen. — [docs.flutter.dev: platform channels](https://docs.flutter.dev/platform-integration/platform-channels)
- The Flutter team's direction ("Flutter's path towards seamless interop") is codegen with **FFIgen** (Objective-C/Swift) and **JNIgen** (Java/Kotlin), enabling **synchronous calls**, tree-shaking, and more data living in the platform layer, unlike method channels. — [Flutter blog: path towards seamless interop](https://blog.flutter.dev/flutters-path-towards-seamless-interop-4bf7d4579d9a) (the claims come from the search summary; the page was not fetched in full, and its original publication is older, likely 2024–2025)
- Pigeon issue "[pigeon] Native Interop" (#182230) was filed on **Feb 11, 2026** by tarrinneal (Pigeon maintainer). It proposes adding **FFI and JNI** backends to Pigeon (config generators, custom classes/enums, sync and async methods) that depend on dart-lang/native publishing and "jnigen without build". Labeled **P1**; status **closed**. Whether it closed as completed was not confirmed. — [flutter/flutter #182230](https://github.com/flutter/flutter/issues/182230)
- VGV (2026) states that platform channels remain the recommended path for typed platform-SDK work, and that Pigeon remains the production way to define them. It also describes jnigen as usable and swiftgen as still experimental. — [Very Good Ventures: Flutter Pigeon in production](https://verygood.ventures/blog/flutter-pigeon-type-safe-platform-channels/) (the claims come from the search summary; the page was not fetched in full)
- **Build hooks are stable** as of **Dart 3.10 / Flutter 3.38**. Hooks can compile native code or download prebuilt libraries and bundle them with a Dart package. Dart 3.13 added **link hooks** and recorded-usage tree-shaking for code assets. — [Dart 3.10 announcement](https://blog.dart.dev/announcing-dart-3-10-ea8b952b6088); [dart.dev: Hooks](https://dart.dev/tools/hooks); [flutter/flutter #129757](https://github.com/flutter/flutter/issues/129757)
- There is still some rough edge: an `objective_c` 9.6.1 hook referenced `Architecture.arm64e`, which no published `code_assets` version had (a version-skew bug in the dart-lang/native packages). — [dart-lang/native #3640](https://github.com/dart-lang/native/issues/3640)
- Roszkowski (May 2026) on the state of interop:
  - **jnigen / `jni` 1.0.0:** usable in published packages (`screen_brightness_monitor`, `play_in_app_update`). Pain points: overload renumbering; R8/ProGuard stripping, which requires `@Keep`; the need to run an Android build before generating bindings; and cryptic regeneration failures.
  - **swiftgen:** "still not stable, but I've had some success using it". Swift must be `@objc`-compatible and `NSObject`-derived, and "Only ObjC-compatible types work". You must commit both the Dart bindings and a generated `.m` file. There is no cross-platform API generation like Pigeon has. The author's view: "I think it's time to move away from methods channels entirely."
  - — [Roszkowski, "jnigen and swiftgen in 2026"](https://roszkowski.dev/2026/swiftgen-jnigen/)
- LLM capability: SwiftEval (2025) found existing multilingual benchmarks have "critical issues specific to their Swift components". Scores dropped significantly on problems requiring Swift-specific language features. — [SwiftEval, arXiv 2505.24324](https://arxiv.org/pdf/2505.24324) (from search snippet)
- AutoCodeBench covers 20 languages, including Dart, Kotlin, and Swift, but the search snippet gave no per-language comparison. — [AutoCodeBench, arXiv 2508.09101](https://arxiv.org/html/2508.09101v1)

### Inferences
- **Mostly supports, with a refinement.** "Write native code only when no good package exists" is right. When the agent does write native code, the default should be **Pigeon** (a Dart-defined schema generating Kotlin/Swift stubs). Pigeon is officially documented, type-safe, and produces code the agent can check with the Dart analyzer on one side and Gradle/Xcode builds on the other.
- jnigen (`jni` 1.0) is a reasonable **Android-only** option for calling platform SDK APIs synchronously without writing Kotlin glue.
- swiftgen/ffigen-Swift should be treated as **experimental**. It is not a default for AI agents, especially since practitioners report agents getting it wrong and the 1.0 API break makes older training data misleading.
- Build hooks make it feasible to bundle C/Rust libraries without a plugin. That is relevant for compute libraries (crypto, codecs), not for platform features like camera or notifications.
- For LLM skill: benchmarks suggest Swift is a weaker area and Dart is a low-resource language. The bigger practical risk is not the language itself but the *native build environment* (Gradle/AGP/Xcode/entitlements/Info.plist/manifest permissions). These are hard for an agent to verify without running device builds. This is an argument for keeping native code small, isolated behind Pigeon, and always build-verified on both platforms.
- Complex platform features (camera, notifications, payments, maps, auth) involve lifecycle, permissions, and background execution on both OSes. Well-maintained packages for these (often Flutter-team or vendor-published, e.g. `camera`, `google_maps_flutter`, `firebase_auth`, Stripe) encode years of edge-case handling. This supports part (b) of the policy.

### Gaps
- I found no benchmark directly comparing LLM accuracy on Flutter platform-channel Kotlin/Swift code with Dart code.
- Whether Pigeon's FFI/JNI backends shipped in a stable Pigeon release (and which version) was not confirmed. The issue is closed, but its resolution was not verified.
- I did not find a current (2026) official Flutter roadmap document with dates for making direct native interop the default.

## 6. Official Flutter/Dart guidance on dependencies and architecture

### Takeaway
Official guidance is pragmatic, not minimalist. It endorses a small set of packages (provider, go_router, freezed/built_value, flutter_lints), keeps state management "personal preference" with SDK `ChangeNotifier` as the baseline, runs Flutter Favorites as the curated list, and uses pub.dev scoring to push migrations (for example, a SwiftPM bonus).

### Cited Findings
- Architecture recommendations: repository pattern, MVVM, immutable models, dependency injection via `provider` (all "Strongly recommend"); go_router (Recommend); freezed/built_value (Recommend, with a warning about build time); `ChangeNotifier` (Conditional). — [Flutter app architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- Flutter Favorites are curated by an ecosystem committee with explicit quality criteria, including verified publisher and high-quality dependencies. — [Flutter Favorite program](https://docs.flutter.dev/packages-and-plugins/favorites)
- The Flutter team uses pub.dev scoring as a lever. Packages without SwiftPM get lower scores. — [Flutter blog: SwiftPM default](https://flutter.dev/blog/saying-goodbye-to-cocoapods-swift-package-manager-is-soon-the-default-in-flutter)

### Inferences
- A FlutterCraft default of "SDK plus the handful of officially recommended packages, then Flutter Favorites, then vetted others" matches official guidance. The policy's "pure-Dart in-house for small helpers" is consistent with, though not explicitly stated in, the official docs.

### Gaps
- I found no explicit official Flutter statement of a "minimize dependencies" principle.

## 7. Supply-chain security for pub packages

### Takeaway
Pub has integrated advisory support backed by the **GitHub Advisory Database**, which is also mirrored in **OSV.dev**. Advisories are shown during `dart pub get` and can be suppressed with `ignored_advisories`. There is **no official `dart pub audit` command** in the docs. Scanning is done with OSV-Scanner or community tools like `dart_audit`.

### Cited Findings
- "Pub uses the GitHub Advisory Database for publishing security advisories for Dart and Flutter packages". Dependency resolution (`dart pub get`) prints warnings such as "http 0.13.0 (affected by advisory: [^0], 1.2.0 available)". The `ignored_advisories` field in pubspec.yaml can suppress them, but "only affects the root package". The page does not mention a `dart pub audit` command. — [dart.dev: security advisories](https://dart.dev/tools/pub/security-advisories)
- pub.dev security policy page. — [pub.dev/security](https://pub.dev/security)
- OSV-Scanner supports the Pub ecosystem and can scan `pubspec.lock` locally or in CI. The community package `dart_audit` checks dependencies against OSV.dev. — [Medium: osv-scanner for Dart/Flutter](https://medium.com/@yshean/scan-your-dart-and-flutter-dependencies-for-vulnerabilities-with-osv-scanner-7f58b08c46f1); [pub.dev: dart_audit](https://pub.dev/packages/dart_audit)
- A pub client path-traversal issue affected Dart SDK <3.11.0 / Flutter <3.41.0 (aggregator source, unverified). — [cvedetails: Dart](https://www.cvedetails.com/vulnerability-list/vendor_id-12360/Dart.html)

### Inferences
- The harness should:
  - surface `pub get` advisory output to the agent and user rather than hiding it;
  - optionally run `osv-scanner --lockfile pubspec.lock` as a quality gate;
  - forbid agents from adding entries to `ignored_advisories` without human approval.
- Advisory databases cover *known vulnerable* versions, not *malicious or hallucinated* new packages. Existence and reputation checks (section 3) are still needed.

### Gaps
- I found no data on the number of pub advisories, or on malware takedowns on pub.dev.
- I found no evidence that pub.dev runs malware scanning on uploads comparable to npm/PyPI partnerships. Not found, not necessarily absent.
