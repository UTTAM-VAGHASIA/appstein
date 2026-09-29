# Native Build Configuration and Deployment-Readiness in Flutter Apps (Android and iOS), as of September 2026

Research date: 2026-09-28. Current Flutter stable at research time: **3.47.x** (3.47.0 released 2026-08-12; 3.47.2 is referenced in GitHub issues filed 2026-09-01/02). Every version below is dated. Toolchain versions change roughly quarterly, so treat anything more than ~3 months old as possibly outdated.

---

## Q1. Android: current toolchain matrix, Flutter's Gradle migrations, and Play requirements that affect build config

### Takeaway
Flutter 3.47 (Aug 2026) ships a template baseline of **Java 17, AGP 9.1.0, Gradle 9.3.1, KGP 2.4.0, compileSdk/targetSdk 36, minSdk 24**. The biggest migration in progress is **AGP 9 "built-in Kotlin"**: Flutter 3.44 supports AGP 9 only with `android.builtInKotlin=false`. Flutter 3.47+ is needed for `android.builtInKotlin=true`. The plugin ecosystem is still migrating, and there are open P1 bugs. Play requires **targetSdk 36 for new apps and updates from 2026-08-31** (extension possible to 2026-11-01) and **16 KB page-size support** for apps that target Android 15+ (from 2025-11-01).

### Cited Findings

**Current Flutter-stable Android baseline (Flutter 3.47, released 2026-08-12)**
- Flutter 3.47 release date is August 12, 2026. Android baseline: Java 17 (minimum), Kotlin Gradle Plugin 2.4.0, AGP 9.1.0, Gradle 9.3.1. SDK defaults: compileSdk 36, targetSdk 36, minSdk 24 — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)
- Secondary summary: "Android build matrix was verified against Java 17 minimum, AGP 9.1.0, Gradle 9.3.1, targeting API 36" — [Flutter 3.47.0 release notes](https://docs.flutter.dev/release/release-notes/release-notes-3.47.0) (seen via search snippet only; not fetched in full)

**Flutter master (post-3.47, i.e., next stable) template constants.** Read from `flutter_tools/lib/src/android/gradle_utils.dart` on the `master` branch, 2026-09-28. These are unreleased and will likely land in the next stable (~Nov 2026):
- Template Gradle `9.5.0`, template AGP `9.3.1`, template KGP `2.4.20`. compileSdk `36`, minSdk `24`, targetSdk `36`, NDK `28.2.13676358` — [gradle_utils.dart (master)](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)
- Thresholds: error/warn Java min `17.0.0`. Max known Gradle `9.5.0`, max known KGP `2.4.20`, max known AGP with full Kotlin support `9.3.1`, max known AGP overall `9.4`. Min build tools `28.0.3` — [gradle_utils.dart (master)](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)
- Flutter's Gradle plugin also enforces a **minimum KGP of 2.2.20** (error: "Your project's Kotlin version (2.2.10) is lower than Flutter's minimum supported version of 2.2.20") — [flutter/flutter#192167](https://github.com/flutter/flutter/issues/192167)
- Older threshold snippets say Flutter warns below AGP 8.6.0 and below Kotlin 2.1.0. These come from a search-result summary and may reflect an older release — [flutter/flutter#179723 via search](https://github.com/flutter/flutter/issues/179723) (unverified exact text)

**Current AGP (Google)**
- The latest AGP is **9.4.0 (September 2026)**. It requires minimum Gradle **9.6.0**, JDK **17**, SDK Build Tools **36.0.0**, and uses NDK default 28.2.13676358. Max API level is **37**. AGP 10 will make the new Variant API mandatory. AGP 9.4 allows a temporary opt-out via `android.newDsl.optOut=:module`. `BaseExtension`, `AppExtension` and `applicationVariants` are deprecated or removed in the 9.x cycle — [AGP release notes](https://developer.android.com/build/releases/gradle-plugin)
- **Conflict to flag:** AGP 9.4 needs Gradle ≥9.6.0, but Flutter master's "max known Gradle" is 9.5.0 and its "max known AGP with full Kotlin support" is 9.3.1. Treat **AGP 9.4 + Flutter as unsupported/untested as of Sept 2026** — [AGP release notes](https://developer.android.com/build/releases/gradle-plugin); [gradle_utils.dart](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)

**AGP 9 / built-in Kotlin migration (the main Android migration in 2026)**
- "Built-in Kotlin is the default in AGP 9 and later. Apps that use the kotlin-android plugin (KGP) fail to build without migration." Flutter **3.44** added AGP 9 support with `android.builtInKotlin=false`. Enabling `android.builtInKotlin=true` requires Flutter **3.47+** — [Migrate to built-in Kotlin](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin)
- Flutter's temporary KGP support "will be removed in a future version of Flutter (when AGP 10.0 becomes the default)" — [Migrate to built-in Kotlin](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin)
- Required `gradle.properties` flags: `android.builtInKotlin=false` (set to true after migration) and `android.newDsl=false`. The Flutter migrator adds them automatically on `flutter run` / `flutter build apk`, and Android Studio adds them too. **Add-to-app hosts must add them manually.** If the app does not apply KGP, only set `android.newDsl=false` and do not migrate to built-in Kotlin — [Built-in Kotlin for app developers](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)
- App migration steps:
  1. Remove `id("kotlin-android")` from the `plugins {}` block.
  2. Replace `android { kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() } }` with a top-level `kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }`.
  3. Set `android.builtInKotlin=true`.

  "Apps fail to build if they use unmigrated Flutter plugins that still apply KGP" — [Built-in Kotlin for app developers](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)
- There is a separate guide for plugin authors — [Built-in Kotlin for plugin authors](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors). Many third-party plugins had open "migrate to built-in Kotlin" issues in 2026, including flutter_timezone, braze, splunk-otel, flutter_tts and open_settings_plus — [flutter_timezone#64](https://github.com/tjarvstrand/flutter_timezone/issues/64), [braze-flutter-sdk#135](https://github.com/braze-inc/braze-flutter-sdk/issues/135), [flutter_tts#646](https://github.com/dlutton/flutter_tts/issues/646)
- Flutter-maintained plugins also needed AGP 9 work: [flutter/flutter#181383](https://github.com/flutter/flutter/issues/181383) (open since Jan 2026) and [flutter/flutter#185121](https://github.com/flutter/flutter/issues/185121)

**Older migrations that still show up in legacy projects**
- **Imperative apply → declarative `plugins {}` block.** Flutter 3.16 added support for applying Flutter's Gradle plugins with the declarative plugins block. Applying them imperatively with `apply from:` is deprecated "and will be removed in a future release". The settings file uses `id "dev.flutter.flutter-plugin-loader" version "1.0.0"`, and GMS/Crashlytics plugins also move into that block — [Deprecated imperative apply](https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply); [flutter/flutter#157583](https://github.com/flutter/flutter/issues/157583)
- **Groovy → Kotlin DSL.** Since Flutter 3.29, `flutter create` generates `android/build.gradle.kts`, `settings.gradle.kts` and `app/build.gradle.kts`. Groovy projects remain supported. Some tools and plugin READMEs assumed Groovy syntax — [Code with Andrea: Kotlin DSL in Flutter 3.29](https://codewithandrea.com/articles/flutter-android-gradle-kts/); [flutter_local_notifications#2568](https://github.com/MaikuB/flutter_local_notifications/issues/2568)
- **Namespace.** AGP 8.0 made `namespace` mandatory and stopped using the manifest `package` attribute. "Namespace not specified" is common with old projects or legacy plugins — [path-finder troubleshooting (2026)](https://blog.path-finder.jp/troubleshooting/how-to-fix-namespace-not-specified-specify-a-namespace-in-the-modules-build-gradle-file-2026-edition/) (secondary source)
- **Java/Gradle mismatch (Flutter 3.10 era).** Java 17 with Gradle <7.3 fails with "Unsupported class file major version 61". Fix tools: `flutter analyze --suggestions` (checks AGP/Java/Gradle compatibility), `./gradlew wrapper --gradle-version=X`, `flutter config --jdk-dir=PATH`. If `JAVA_HOME` is set, Flutter uses it instead of Android Studio's bundled JDK. Note that this page's version recommendation (Gradle 7.3–7.6.1) is **stale** — [Android Java Gradle migration guide](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide)
- **Default abiFilters (Flutter 3.35).** For non-debuggable builds, the Flutter Gradle plugin sets `abiFilters` to `armeabi-v7a`, `arm64-v8a` and `x86_64`. This breaks custom abiFilters in buildTypes/productFlavors. Opt-outs: `--split-per-abi`, `abiFilters.clear()` in defaultConfig, or `-Pdisable-abi-filtering=true` — [Default abiFilters](https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android)
- **Other items.** KitKat (API 19) support was dropped in Flutter 3.22. v1 embedding Java APIs were removed in 3.29. "Restrict command-line flags for prebuilt Android release binaries" is listed for 3.47 but was not yet in stable — [Breaking changes index](https://docs.flutter.dev/release/breaking-changes)
- **Bypass flag.** `--android-skip-build-dependency-validation` skips Flutter's AGP/Gradle/Kotlin/Java validation — [Android Java Gradle guide / search summary](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide)

**Google Play requirements that affect build config**
- **Target API.** From **2026-08-31**, new apps and app updates must target **API 36 (Android 16)**. Exceptions: Wear OS and Automotive need API 35; TV and XR need API 34. Existing apps must target API 35+ to stay available to new users on newer OS versions. Developers can request an **extension to 2026-11-01** — [Play Console Help: target API level](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en)
- **16 KB page size.** From **2025-11-01**, all new apps and updates that target Android 15+ must support 16 KB page sizes. Pure Java/Kotlin apps need no changes. Apps with native code must be recompiled with current toolchains, and SDKs must be updated. "React Native and Flutter already support this." Compliance can be checked in the Play Console App Bundle Explorer — [Android Developers Blog, May 2025](https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html)
- Secondary sources report a later hard stop ("May 1, 2026 all updates rejected if not compliant") and say NDK r28+ is compliant by default, while r27 needs extra flags. **This is unverified against a primary source** — [freeCodeCamp](https://www.freecodecamp.org/news/google-16-kb-page-size-requirement-what-to-do/) and Medium posts (search snippets)
- **Android 17 items surfaced in Flutter docs.** Flutter 3.44 added a breaking-change note: "Large screen orientation and resizability restrictions ignored on Android 17" — [Breaking changes index](https://docs.flutter.dev/release/breaking-changes). Android 17 also adds v3.2 APK signing with PQC hybrid (ML-DSA) signatures. Play App Signing users should wait for Google. Self-managed keys must be rotated with updated `apksigner` to a **new** classical key — [Flutter: Build and release an Android app](https://docs.flutter.dev/deployment/android)
- **AAB.** Flutter docs call the App Bundle "preferred by Google Play Store" (`flutter build appbundle`) — [Flutter Android deployment](https://docs.flutter.dev/deployment/android)

### Inferences
- A "deployment-ready" Flutter Android project as of Sept 2026 should look like this:
  - Kotlin DSL (`.kts`) files and the declarative plugins block
  - `namespace` set
  - Java 17 (and not a newer JDK that the Gradle wrapper can't run)
  - Gradle 9.3.1 / AGP 9.1.0 on stable 3.47. AGP 8.x also still works.
  - compileSdk and targetSdk 36; minSdk ≥24
  - `android.newDsl=false` present
  - Built-in Kotlin **off** unless every plugin has migrated (and given #192167, possibly off regardless until a fix ships)
- Pinning to Flutter's `flutter.compileSdkVersion` and `flutter.targetSdkVersion` variables automatically satisfies the Play target-API rule on current Flutter. Hardcoding integers is the main way projects fall behind.
- 16 KB compliance for Flutter apps is almost entirely a **plugin and native-library** problem, not a Flutter engine problem.

### Gaps
- I could not fetch the full Flutter 3.47.0 release-notes page, so the exact wording of the "verified baseline" is from a search snippet plus the official blog.
- I could not find Flutter-official docs on the exact warn/error thresholds for AGP and Gradle in 3.47 stable (as opposed to master). Only master constants were read.
- I found no primary-source confirmation of the "May 1, 2026" 16 KB hard-stop date.
- I found no official statement on whether Flutter will move templates to AGP 9.4 / Gradle 9.6.

---

## Q2. iOS/macOS: CocoaPods vs SPM, minimum targets, Xcode, privacy manifests, UIScene, and signing

### Takeaway
**SPM is on by default since Flutter 3.44 (~June 2026).** CocoaPods is used only as an automatic fallback for plugins without SPM support. CocoaPods trunk becomes **permanently read-only on 2026-12-02**. Flutter 3.47 raised minimum deployment targets to **iOS 15 / macOS 12**. App Store uploads need **Xcode 26 / iOS 26 SDK since 2026-04-28**. **Xcode 27 (iOS 27 SDK) makes UIScene mandatory:** non-migrated Flutter apps crash at launch. Flutter auto-migrates unmodified AppDelegates since 3.41.

### Cited Findings

**Swift Package Manager**
- "As of the 3.44 release, Flutter's SwiftPM support is on by default. Upgrading Flutter and running your app automatically adds SwiftPM integration" — [Flutter blog: Saying goodbye to CocoaPods](https://flutter.dev/blog/saying-goodbye-to-cocoapods-swift-package-manager-is-soon-the-default-in-flutter) (via search summary)
- Flutter 3.44 is dated ~June 1, 2026 by a secondary source — [Somnio 3.44 migration guide](https://somniosoftware.com/blog/flutter-3-44-migration-guide-agp-9-swift-package-manager-and-breaking-changes)
- Opt-out options:
  - Per project, in `pubspec.yaml`: `flutter: config: enable-swift-package-manager: false`
  - Globally: `flutter config --no-enable-swift-package-manager`

  Flutter **automatically falls back to CocoaPods** for plugins without SPM support — [SPM for app developers](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
- The migration edits the Xcode project:
  - adds a `FlutterGeneratedPluginSwiftPackage` package dependency
  - adds a scheme **build pre-action** ("Run Prepare Flutter Framework Script")
  - modifies `project.pbxproj` and `.xcscheme`

  To remove CocoaPods entirely (only when all plugins support SPM): run `pod deintegrate`, delete `Podfile`, `Podfile.lock`, `Pods/` and `.symlinks/`, then `flutter clean && flutter pub get`. If a plugin needs a higher OS minimum, raise it in Xcode and run `flutter build ios --config-only` — [SPM for app developers](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
- At the 3.47 announcement, 92 of the top 100 iOS plugins had migrated to SPM. Flutter 3.47 also filters unneeded SwiftPM package schemes earlier to speed up builds — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)
- Known SPM issues:
  - Some popular plugins had not fully migrated as of 3.44 (cited: permission_handler, firebase_remote_config, device_info_plus, sentry_flutter).
  - SPM-generated files can cause "a large number of false positive errors" in Dart analysis.

  [Somnio](https://somniosoftware.com/blog/flutter-3-44-migration-guide-agp-9-swift-package-manager-and-breaking-changes) (secondary; plugin status may have changed since)

**CocoaPods trunk timeline**
- The CocoaPods timeline:
  - May 2025: `prepare_command` disallowed in podspecs.
  - Sept–Oct 2026: second notice to contributors.
  - **Nov 1–7, 2026**: test run of read-only mode.
  - **Dec 2, 2026**: trunk permanently stops accepting new podspecs.

  "This will keep all existing builds working." Existing pods stay installable via the CDN — [CocoaPods blog](https://blog.cocoapods.org/CocoaPods-Specs-Repo/)

**Minimum deployment targets and Xcode**
- Flutter 3.47 raised minimums to **iOS 13 → 15** and **macOS 10.15 → 12**. Intel Mac support is being phased out: the CLI warns on Intel builds and future releases will error. Opt in to arm64-only with `flutter config --enable-macos-arm64-only` — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)
- **Conflict or stale docs:** the Flutter iOS deployment page still says "Flutter supports iOS 13 and later" — [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios). Trust the 3.47 blog. The doc page appears outdated.
- Flutter 3.47 adds guided error messages when iOS/macOS builds fail due to a low minimum version — [Flutter 3.47 search summary](https://flutter.dev/blog/whats-new-in-flutter-3-47)
- **Apple SDK minimum:** from **2026-04-28**, App Store Connect uploads must be built with **Xcode 26+** against the iOS 26 (and sibling) SDKs. This does not constrain the deployment target — [Apple Developer News: upcoming requirements](https://developer.apple.com/news/upcoming-requirements/); [Expo blog](https://expo.dev/blog/app-store-connect-minimum-sdk-26)
- The iOS 26 SDK applies Liquid Glass to native UIKit components by default — [DEV / search summary](https://dev.to/arshtechpro/ios-26-sdk-is-now-mandatory-here-is-what-actually-changes-for-your-app-39m4) (secondary). This matters little for Flutter-rendered UI but affects native views and dialogs (inference).

**UIScene lifecycle (mandatory with Xcode 27)**
- Timeline: landed in Flutter 3.38. Since **3.41**, `flutter run` / `flutter build ios` auto-migrate projects whose AppDelegate is unmodified (prints "Finished migration to UIScene lifecycle").

  "Beginning with Xcode 27 (iOS 27 SDK), UIScene lifecycle is mandatory. Flutter apps that haven't adopted it will crash on startup when built with Xcode 27" — [Flutter: UIScene adoption](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)
- The requirement depends on the SDK, not the OS: apps built with an older SDK still launch on iOS 27 — [search summary of Flutter/ecosystem docs](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)
- Manual migration (needed for a custom AppDelegate or Flutter <3.41):
  - `AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate`, with plugin registration moved into `didInitializeImplicitFlutterEngine(_ engineBridge:)` → `GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)`.
  - MethodChannels and platform-view factories move there too, using `engineBridge.applicationRegistrar.messenger()`.
  - Add `UIApplicationSceneManifest` to Info.plist, with `UISceneDelegateClassName` = `FlutterSceneDelegate` (or a custom `$(PRODUCT_MODULE_NAME).SceneDelegate`), `UISceneConfigurationName` = `flutter` and `UISceneStoryboardFile` = `Main`.
  - **Accessing FlutterViewController in `didFinishLaunchingWithOptions` will crash.**
  - Opt-out of the warning: `flutter: config: enable-uiscene-migration: false`.

  [Flutter: UIScene adoption](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)
- Plugins must adopt `FlutterSceneLifeCycleDelegate`, call `registrar.addSceneDelegate(instance)`, and require `flutter: ">=3.38.0"`. Mappings include `application:openURL:` → `scene:openURLContexts:` and `continueUserActivity` → `scene:continue:` — [Flutter: UIScene adoption](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)
- Third-party SDKs with deep-link or push hooks (e.g., Customer.io) flagged crash risk and an iOS 27 deadline (Sept 2026) — [customerio-flutter#306](https://github.com/customerio/customerio-flutter/issues/306); [Courier blog](https://www.courier.com/blog/ios-27-uiscenedelegate-push-notification-deadline-what-breaks-and-how-to)

**Privacy manifests**
- Since **May 1, 2024**, uploads whose code (including third-party libraries) references "required reason" APIs must declare them in `NSPrivacyAccessedAPITypes` in `PrivacyInfo.xcprivacy`. Otherwise App Store Connect sends **ITMS-91053: Missing API declaration**. Categories commonly hit by Flutter apps and plugins: file timestamp, system boot time, disk space, active keyboard, and UserDefaults APIs — [avanderlee](https://www.avanderlee.com/xcode/missing-api-declaration-required-reason-itms-91053/); [flutter/flutter#145269](https://github.com/flutter/flutter/issues/145269); [dd-sdk-flutter#587](https://github.com/DataDog/dd-sdk-flutter/issues/587)
- The fix is usually updating plugins, which now ship their own manifests. The app should also include its own `PrivacyInfo.xcprivacy` for app-level usage — [avanderlee](https://www.avanderlee.com/xcode/missing-api-declaration-required-reason-itms-91053/)

**Signing, versioning and export (Flutter docs)**
- **Signing:** automatic signing with the Team selected is sufficient for most apps. Register an explicit Bundle ID in the developer portal and on App Store Connect — [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- **Versioning:** `version: 1.0.0+1` → `CFBundleShortVersionString` / `CFBundleVersion`. Each upload needs a unique build number. Override with `--build-name` / `--build-number` — [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- **Build and upload:**
  - `flutter build ipa` supports `--export-method ad-hoc|development|enterprise`, `--export-options-plist=`, and `--obfuscate --split-debug-info=<dir>`.
  - Upload via Transporter, `xcrun altool --upload-app` with an API key, or Xcode Organizer.
  - The docs show an automated alternative using Codemagic CLI tools (`app-store-connect fetch-signing-files`, `keychain`, `xcode-project use-profiles`).

  [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- Flutter 3.47 shows Team ID plus Team Name when selecting a certificate and gives clearer provisioning-profile errors — [What's new in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)

### Inferences
- New projects on 3.47 should be SPM-only where possible. Projects with a Podfile will keep working after 2026-12-02 for already-published pods. However, any plugin that still relies on CocoaPods for **new** native SDK versions will be frozen, which is a medium-term build-breakage risk to monitor.
- Any existing project with a customised AppDelegate (common with Firebase, push, deep links, or method channels) will not be auto-migrated to UIScene. It becomes a launch crash as soon as the team switches to Xcode 27. This is a high-value automated check for a harness.
- Raising `IPHONEOS_DEPLOYMENT_TARGET` to 15 must happen in three places: the Xcode project, the Podfile `platform :ios` line (if CocoaPods is still used), and plugin podspecs/Package.swift. Mismatches are a classic warning or failure source.

### Gaps
- I did not verify the Xcode 27 **App Store upload** mandate date. Apple typically requires the new SDK from about April of the following year, which suggests ~April 2027, but this is **unverified**.
- I did not fetch Apple's current Info.plist usage-description rules. The known pattern: missing `NS*UsageDescription` for a referenced permission API leads to rejection or a crash. This is based on prior knowledge and has no URL gathered here.
- I did not confirm the exact date of the SPM-default blog post.

---

## Q3. The most common "won't build" failures (2025–2026) and their root causes

### Takeaway
Most build failures come from **version skew**: between Flutter's Gradle plugin, AGP, Gradle, KGP and the JDK, and between app config and **plugin** config (unmigrated KGP, missing namespace, Groovy-only snippets, deployment targets). In Sept 2026, the newest hazards are AGP 9.x built-in Kotlin and AGP 9.1+/Gradle 9.3 incompatibilities with Flutter's Gradle plugin.

### Cited Findings
- **AGP built-in Kotlin version rejected (open P1, 2026-09-02).** On Flutter 3.47.2, with `android.builtInKotlin=true` on AGP 9.3.2/9.4.0/9.5.0-alpha03 (which bundle Kotlin 2.2.10), `DependencyVersionChecker.checkKGPVersion` fails the build with "Kotlin version (2.2.10) is lower than Flutter's minimum supported version of 2.2.20". Users cannot bump the bundled Kotlin. A fix PR (#192206) is in progress — [flutter/flutter#192167](https://github.com/flutter/flutter/issues/192167)
- **AGP 9.1 + Gradle 9.3.1 fatal configuration errors (2026-09-01, open).** On Flutter 3.47.2, AGP 9.1.0, Gradle 9.3.1, SDK 37, Kotlin 2.4.0 on Windows, users see:
  - "Failed to create service 'AndroidLocationsBuildService'"
  - `ClassCastException: ApplicationExtensionImpl cannot be cast to AbstractAppExtension` (a legacy-DSL cast against the new DSL)
  - "Circular evaluation detected"

  Toggling newDsl/builtInKotlin did not help — [flutter/flutter#192111](https://github.com/flutter/flutter/issues/192111) (single report, status "waiting for response")
- **KGP applied by unmigrated plugins under AGP 9.** Apps "fail to build if they use unmigrated Flutter plugins that still apply the Kotlin Gradle Plugin" — [Built-in Kotlin for app developers](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers). Community write-ups say AGP 9 failures occur "at configuration time before code compiles" — [search summary: Dev Genius article](https://blog.devgenius.io/flutters-docs-say-don-t-upgrade-to-agp-9-here-s-what-actually-breaks-2ffdc5f99c4b) (article returned 403; only the snippet was seen)
- **Namespace not specified.** Legacy plugins or old apps under AGP 8+ fail because the manifest `package` is no longer used — [path-finder 2026](https://blog.path-finder.jp/troubleshooting/how-to-fix-namespace-not-specified-specify-a-namespace-in-the-modules-build-gradle-file-2026-edition/)
- **Partial upgrades.** Bumping AGP in `settings.gradle(.kts)` without aligning the Gradle wrapper and JDK causes cascading config errors — [path-finder 2026](https://blog.path-finder.jp/troubleshooting/how-to-fix-namespace-not-specified-specify-a-namespace-in-the-modules-build-gradle-file-2026-edition/)
- **JDK too new or too old for the Gradle wrapper.** Example: Java 17 + Gradle <7.3 gives "Unsupported class file major version 61". Android Studio's bundled JDK silently changes which JDK Flutter uses unless `JAVA_HOME` or `flutter config --jdk-dir` is set — [Android Java Gradle guide](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide). Flutter's compat list shows Java 25 needs Gradle ≥9.1.0 — [gradle_utils.dart](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)
- **Imperative apply migration failures.** Auto-migration from `apply from:` to the plugins block fails for customised files — [flutter/flutter#146033](https://github.com/flutter/flutter/issues/146033)
- **minSdk overwrite.** The Flutter Gradle plugin overwrote an explicit `minSdk` with `flutter.minSdkVersion`, so it could not be set to 21 — [flutter/flutter#177141](https://github.com/flutter/flutter/issues/177141) (title only). Related: plugins requiring a higher minSdk than the app is the classic "uses-sdk:minSdkVersion X cannot be smaller than version Y declared in library" failure (prior knowledge; no URL gathered).
- **compileSdk too low for plugins.** Plugins compiled against newer SDKs require the app's compileSdk to be ≥ theirs. There are many "error while using compile sdk 35" reports — [Medium: compile sdk 35 error](https://medium.com/@henryliang3027/flutter-error-while-using-compile-sdk-version-35-8bcdd4472835); [DEV: target SDK 35 upgrade](https://dev.to/junian/troubleshooting-flutter-android-app-to-target-sdk-35-upgrade-50gk)
- **abiFilters conflicts.** Since 3.35, custom abiFilters in buildTypes/flavors break — [Default abiFilters](https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android)
- **Groovy snippets pasted into `.kts`.** Plugin READMEs written for Groovy confused users after 3.29 — [flutter_local_notifications#2568](https://github.com/MaikuB/flutter_local_notifications/issues/2568)
- **iOS failures:**
  - Low minimum deployment target versus a plugin's requirement (3.47 added guided messages)
  - UIScene crash with Xcode 27 for custom AppDelegates
  - ITMS-91053 privacy manifest warnings or rejections
  - SPM false-positive analyzer errors

  Sources: [Flutter 3.47 blog](https://flutter.dev/blog/whats-new-in-flutter-3-47), [UIScene doc](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate), [flutter/flutter#145269](https://github.com/flutter/flutter/issues/145269), [Somnio](https://somniosoftware.com/blog/flutter-3-44-migration-guide-agp-9-swift-package-manager-and-breaking-changes)

### Inferences
- The root cause of most failures is that **a Flutter app's native build is the union of the app's Gradle/Xcode config and every plugin's config**. The app author doesn't control plugin build files. A harness should therefore resolve and inspect plugin build files (in the pub cache: each plugin's `android/build.gradle[.kts]`, podspec, Package.swift) before upgrading anything. It should report which plugins apply KGP, lack a namespace, or require a higher minSdk, compileSdk or iOS target.
- The safest harness policy in Sept 2026:
  - Stay on the Flutter-template toolchain versions for the installed Flutter SDK.
  - Never let users or agents bump AGP beyond Flutter's "max known" values.
  - Run `flutter analyze --suggestions` and a dry `flutter build apk --config-only` / `flutter build ios --config-only` as gates.

### Gaps
- I found no quantitative data (e.g., counts of GitHub issues by label t: gradle / a: build) ranking failure frequency. Rankings above are qualitative.
- Reddit threads were not surfaced by search. The community evidence here is mostly GitHub issues and blogs.

---

## Q4. Deployment-setup concerns: flavors, icons, splash, signing, IDs, versioning, obfuscation, R8

### Takeaway
Flutter's official docs cover signing, versioning, obfuscation, R8 and AAB in detail. Icons, splash screens and flavors are left to manual native edits or community packages. The docs give copy-pasteable `build.gradle.kts` signing snippets and warn that the application ID cannot change after the first Play upload.

### Cited Findings
- **Android signing:**
  - Create the upload keystore with `keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`. `-storetype JKS` is only needed for Java 9+ (PKCS12 is the default).
  - `android/key.properties` holds storePassword, keyPassword, keyAlias and storeFile. Windows paths need double backslashes. **Never commit it.**
  - The `.kts` snippet loads properties into `signingConfigs.create("release")` and `buildTypes.release.signingConfig`.
  - Run `flutter clean` after Gradle signing changes.
  - Play App Signing: upload key versus app signing key.

  [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- **Application ID and namespace:** these must be unique and **cannot change after the first Play upload**. If renamed, update `namespace` and move MainActivity to the matching package directory — [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- **SDK versions:** compileSdk, minSdk and targetSdk are "managed by Flutter" via `flutter.*` variables. Replacing them with integers "locks" them and prevents automatic updates on Flutter upgrade — [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- **Versioning:** `version: 1.0.0+1` → versionName/versionCode (Android) and CFBundleShortVersionString/CFBundleVersion (iOS). Override with `--build-name` / `--build-number`. `--split-per-abi` changes version codes per ABI unless `-P force-version-code-ignoring-abi=true` is passed — [Flutter Android deployment](https://docs.flutter.dev/deployment/android); [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- **R8 and obfuscation:**
  - R8 is **enabled by default** for release builds. `--no-shrink` has no effect.
  - Dart obfuscation: `flutter build appbundle --obfuscate --split-debug-info=./symbols`. The symbol files are needed to de-obfuscate crash stack traces.

  [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- **AGP 9.4.0-alpha03** now includes L8 obfuscation mapping in the app's `mapping.txt` — [AGP release notes](https://developer.android.com/build/releases/gradle-plugin)
- **Default ABIs:** armeabi-v7a, arm64-v8a, x86_64. Use `--split-per-abi` for sideloaded APKs — [Flutter Android deployment](https://docs.flutter.dev/deployment/android)
- **Adaptive icons:** place icons in `res/mipmap-*` and reference `@mipmap/ic_launcher`, or use `flutter_launcher_icons`. On iOS, replace placeholders in `Assets.xcassets` — [Flutter Android deployment](https://docs.flutter.dev/deployment/android); [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- **Android 12+ splash:** the system splash is a window background, icon and icon background, with no background images. The OS masks the icon into a centre circle. The splash doesn't show when launching from a notification or from some IDE run paths — [flutter_native_splash](https://pub.dev/packages/flutter_native_splash); [sagnikbhattacharya.com](https://sagnikbhattacharya.com/blog/flutter-app-icons-splash-screen) (secondary)
- **Flavors plus abiFilters:** Flutter can't safely preserve ABI filter customisations in `productFlavors` or `buildTypes` (use `-Pdisable-abi-filtering=true`) — [Default abiFilters](https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android)
- **Firebase and GMS/Crashlytics Gradle plugins** must be declared in the settings-file `plugins {}` block under the declarative model — [Deprecated imperative apply](https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply)

### Inferences
- A harness should treat these as **one-way doors** and gate them behind explicit confirmation:
  - applicationId / bundle ID (cannot change after the first store upload)
  - upload keystore creation and backup (losing it without Play App Signing is unrecoverable)
  - first versionCode
- Secrets hygiene should be enforced automatically. `key.properties`, `*.jks`, `*.keystore`, `.p8`, `GoogleService-Info.plist`/`google-services.json` (debatable) and `ExportOptions.plist` with team IDs should be covered by `.gitignore` checks.
- Keep `--split-debug-info` output out of the repo and store it per build number, so crash reports can be symbolicated.

### Gaps
- I did not fetch the official Flutter flavors docs (`docs.flutter.dev/deployment/flavors` and `/flavors-ios`), so flavor-specific rules (e.g., `--flavor` mapping to Xcode schemes, per-flavor bundle IDs) are not cited here.
- I did not check whether Flutter docs now cover custom R8 keep-rule needs for plugins (e.g., reflection-based plugins). This remains a known source of release-only crashes but has no source gathered.

---

## Q5. Existing tools that automate parts of this: coverage and weaknesses

### Takeaway
Community tools cover narrow slices: icons, splash, flavor scaffolding, CI signing and OTA Dart patches. None of them validate cross-cutting toolchain compatibility (AGP/Gradle/KGP/JDK/plugins, or iOS target/SPM/UIScene/privacy). Several are "raster-first" or "string-patch" generators, which break on non-template native files such as Kotlin DSL, custom AppDelegates or SPM projects.

### Cited Findings
- **flutter_launcher_icons / flutter_native_splash:**
  - Both are raster-first: they resize one PNG and "string-patch" native files.
  - flutter_native_splash feeds a static image to the Android 12 SplashScreen API.
  - Android 12 constraints apply: no background image, and the icon is circle-masked.
  - Historical dependency conflicts between the two packages (via `args` versions) have occurred.

  [flutter_adaptive_studio (competitor's claims)](https://pub.dev/packages/flutter_adaptive_studio); [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons); [flutter_native_splash](https://pub.dev/packages/flutter_native_splash); [flutter_launcher_icons#316](https://github.com/fluttercommunity/flutter_launcher_icons/issues/316)
- **flutter_flavorizr (v2.6.0, ~July 2026):**
  - Generates Android productFlavors, manifest entries and resources; iOS/macOS xcconfigs, targets, schemes and launch screens; Firebase configs; per-flavor icons.
  - It "works better on a new and clean Flutter project". Existing projects may error because processors depend on specific file structures.
  - It modifies existing files (build.gradle, AndroidManifest.xml, Info.plist).
  - macOS flavors can't be run from the terminal due to a Flutter SDK bug.
  - Its docs don't mention Kotlin DSL or SPM support.

  [flutter_flavorizr on pub.dev](https://pub.dev/packages/flutter_flavorizr)
- **Shorebird:**
  - OTA code push for Dart only.
  - It cannot patch Java/Kotlin/Swift/ObjC, native build files, plugin native code, permissions, assets (images/fonts), or the Flutter version. These require a full store release.
  - It supports Android and iOS.

  [Shorebird FAQ](https://docs.shorebird.dev/code-push/faq/); [DEV 2026 guide](https://dev.to/techwithsam/how-to-push-over-the-air-ota-flutter-updates-with-shorebird-complete-2026-guide-4d35)
- **Codemagic CLI tools:** the official Flutter iOS docs show `codemagic-cli-tools` automating App Store Connect signing:
  - `app-store-connect fetch-signing-files --create`
  - `keychain initialize/add-certificates`
  - `xcode-project use-profiles`
  - `app-store-connect publish`

  Always restore the login keychain afterwards. Codemagic also integrates Shorebird — [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios); [Codemagic docs: Shorebird](https://docs.codemagic.io/flutter-distributing/shorebird/)
- **Android Studio AGP Upgrade Assistant:** recommended for AGP bumps, and it adds the AGP 9 gradle.properties flags automatically — [search summary](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide); [Built-in Kotlin for app developers](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)
- **Flutter CLI's own migrators:**
  - AGP 9 gradle.properties flags
  - UIScene (3.41+ auto-migration)
  - SPM Xcode project integration (3.44+)
  - declarative plugins block (partially automated; can fail on custom files, [#146033](https://github.com/flutter/flutter/issues/146033))
  - dependency-version checks (`flutter analyze --suggestions`)
  - `dart fix` for Dart API breaking changes

  [Built-in Kotlin](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers); [UIScene](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate); [SPM](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers); [Breaking changes index](https://docs.flutter.dev/release/breaking-changes)

### Inferences
- A harness adds the most value by orchestrating Flutter's own migrators (`flutter build … --config-only`, `flutter analyze --suggestions`) plus plugin-graph inspection, rather than writing native config by hand.
- Icon and splash packages should run **after** the project's native structure is final (Kotlin DSL, UIScene, SPM). Their output should be diffed and verified, because these tools patch files by string matching.

### Gaps
- **fastlane, very_good_cli (Very Good Core template), Codemagic cloud and Bitrise:** I did not fetch current docs in this session, so I have no verified 2026 details. Prior knowledge:
  - fastlane (`match` for iOS certs, `supply` for Play uploads) is widely used, but it is Ruby-based and CocoaPods-adjacent.
  - very_good_cli's template ships three flavors (development/staging/production) with pre-wired native config. Whether it has been updated for Kotlin DSL, AGP 9, SPM and UIScene is **unverified**.
- I found nothing on whether flutter_launcher_icons or flutter_native_splash handle SPM-only projects or UIScene storyboards correctly in 2026.

---

## Q6. Is there a machine-readable compatibility matrix (Flutter ↔ AGP ↔ Gradle ↔ Kotlin ↔ JDK)?

### Takeaway
No official published JSON/YAML matrix was found. The closest machine-readable source of truth is **Flutter's own `flutter_tools/lib/src/android/gradle_utils.dart`**, versioned per Flutter tag. It encodes template versions, warn/error thresholds, the "max known" AGP/Gradle/KGP, and Java↔Gradle and AGP↔Java compatibility lists copied from Gradle and Android docs. Upstream tables are HTML pages on docs.gradle.org and developer.android.com.

### Cited Findings
- `gradle_utils.dart` contains:
  - template constants (Gradle/AGP/KGP/compileSdk/minSdk/targetSdk/NDK)
  - thresholds (Java min, max known Gradle/KGP/AGP, oldest considered AGP 3.3.0 / Gradle 4.10.1 / KGP 1.6.20)
  - `_javaGradleCompatList`, sourced from `docs.gradle.org/current/userguide/compatibility.html#java` (e.g., Java 17–25 → Gradle ≥7.3; Java 25–26 → Gradle ≥9.1.0)
  - `_javaAgpCompatList`, sourced from `developer.android.com/build/releases/gradle-plugin` (AGP 8.0–9.4 → Java 17+; AGP 7.0–7.4 → Java 11+)

  [gradle_utils.dart (master)](https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/android/gradle_utils.dart)
- Flutter's Gradle plugin also has a `DependencyVersionChecker` (Kotlin min 2.2.20 at 3.47.2) — [flutter/flutter#192167](https://github.com/flutter/flutter/issues/192167)
- AGP's official compatibility table (Gradle/JDK/Build Tools/NDK/max API per AGP version) is an HTML page. AGP 9.4: Gradle 9.6.0, JDK 17, Build Tools 36.0.0, NDK 28.2.13676358, API 37 — [AGP release notes](https://developer.android.com/build/releases/gradle-plugin)
- Flutter exposes the check to users via `flutter analyze --suggestions` — [Android Java Gradle guide](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide)

### Inferences
- **Recommended approach for FlutterCraft:**
  1. For the user's installed Flutter version, fetch `gradle_utils.dart` at the matching tag (`https://raw.githubusercontent.com/flutter/flutter/<version>/packages/flutter_tools/lib/src/android/gradle_utils.dart`), or read it from the local SDK at `$FLUTTER_ROOT/packages/flutter_tools/lib/src/android/gradle_utils.dart`.
  2. Regex-extract the constants.
  3. Combine them with the Flutter Gradle plugin's `DependencyVersionChecker` (in `packages/flutter_tools/gradle/src/main/kotlin/…`; exact path not verified) and the output of `flutter analyze --suggestions`.

  This gives a per-SDK, authoritative matrix with no third-party dependency.
- For iOS there is no equivalent code-level matrix. The minimum deployment target lives in the Flutter template (`ios/Flutter/AppFrameworkInfo.plist` / `MinimumOSVersion` and the Xcode project) of the installed SDK. That would be the source to read (inference; the path is not verified in this session).
- Upstream tables change often. Even inside Flutter master, AGP 9.4's Gradle 9.6 requirement already exceeds Flutter's "max known Gradle 9.5.0". A harness should treat "newer than Flutter's max known" as **unsupported**, not "probably fine".

### Gaps
- I found no community-maintained JSON matrix (e.g., on GitHub) for Flutter↔AGP↔Gradle↔Kotlin. Such a thing may exist, but none surfaced in searches.
- I did not verify the file path of `DependencyVersionChecker` inside the Flutter Gradle plugin sources.
