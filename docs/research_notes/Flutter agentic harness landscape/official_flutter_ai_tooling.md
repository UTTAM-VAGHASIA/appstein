# Official Google / Flutter / Dart AI tooling for Flutter development (state as of 2026-09-28)

Method note: Most facts below were verified directly against primary sources on 2026-09-28 via the GitHub API (repo contents, commits, issues, manifests), the pub.dev API, the source Markdown of docs.flutter.dev / dart.dev / blog.flutter.dev (in the `flutter/website` and `dart-lang/site-www` repos), and live pages on developers.google.com. GitHub URLs point at the default branch. "Inference" means my own reasoning, not a stated fact.

## 1. flutter/agent-plugins: skills, rules, distribution, cadence, issues, scope

### Takeaway
`flutter/agent-plugins` (previously named `flutter/skills`) is the official "Dart and Flutter" agent plugin (v1.0.6). It bundles 10 Flutter skills, 15 Dart skills auto-synced from dart-lang/skills, one rule (proactive hot reload), the `dart mcp-server` config and two Stop hooks (format and analyze), with manifests for Claude Code, Codex, Cursor and Antigravity. The Flutter skills are narrow, "happy path" task recipes and have not changed since 21 Apr 2026. None of them covers native build config (Gradle, AGP, Kotlin, iOS), release or deployment, theming and design systems, state-management libraries, or accessibility. Most of those topics are only proposals on a P1 roadmap issue.

### Cited Findings
**Identity, stats, policy**
- README: "Agent plugins for Flutter, maintained by the Flutter team... These plugins bundle together skills, MCP server configuration, and rules to provide tailored workflows and instructions for **happy path** Flutter development." It also says: "We aren't accepting pull requests at this time." — [README](https://github.com/flutter/agent-plugins)
- Repo created 2026-02-25, last push 2026-09-25, about 3,001 stars, 34 open issues/PRs, BSD-3-Clause, about 423 commits. — [GitHub API: flutter/agent-plugins](https://github.com/flutter/agent-plugins)
- The May 2026 launch blog links to `github.com/flutter/skills`, and its install command is `npx skills add flutter/skills ...`. The repo has since been renamed or replaced by `flutter/agent-plugins`, and current docs use `npx skills add flutter/agent-plugins`. — [Introducing Skills for Dart and Flutter (2026-05-06)](https://blog.flutter.dev/introducing-skills-for-dart-and-flutter); [Get started with AI](https://docs.flutter.dev/ai/get-started)

**Full skill list (10 Flutter skills, all `last_modified: Tue, 21 Apr 2026`, 130–255 lines each)** — [skills/](https://github.com/flutter/agent-plugins/tree/main/skills)
- `flutter-add-integration-test`: configures Flutter Driver and turns MCP interactions into permanent `integration_test` tests. It mentions `./gradlew app:assembleAndroidTest` for the Android test APK, and its checklist says "Run `launch_app` via MCP".
- `flutter-add-widget-preview`: widget previews via the `previews.dart` system. It is the only skill that mentions ThemeData.
- `flutter-add-widget-test`: WidgetTester component tests.
- `flutter-apply-architecture-best-practices`: layered UI/Logic/Data architecture. ViewModels "Extend `ChangeNotifier`", views use `ListenableBuilder`, and DI goes through "`provider` or `get_it`". There is no Riverpod or Bloc guidance.
- `flutter-build-responsive-layout`: LayoutBuilder, MediaQuery, Expanded/Flexible. Its only accessibility content is one line about touch-target size and keyboard navigation.
- `flutter-fix-layout-issues`: RenderFlex overflow and unbounded constraints, using MCP tools.
- `flutter-implement-json-serialization`: manual `fromJson`/`toJson` with `dart:convert` (not json_serializable).
- `flutter-setup-declarative-routing`: `MaterialApp.router` plus go_router. It includes an `Info.plist` deep-link opt-in step.
- `flutter-setup-localization`: flutter_localizations, intl, `l10n.yaml`.
- `flutter-use-http-package`: REST calls with `package:http`.
- The README gives each skill a description and an example prompt, for example "Add an integration test that validates the checkout experience". — [README](https://github.com/flutter/agent-plugins)
- Every SKILL.md frontmatter contains `metadata.model: models/gemini-3.1-pro-preview`. A community comment points out that this field "is inert outside Gemini" because Claude Code ignores it. — [issue #88 comment, 2026-05-03](https://github.com/flutter/agent-plugins/issues/88)

**Dart skills bundled into the plugin**
- The plugin's `skills/` directory also holds 15 `dart-*` skills, synced automatically from dart-lang/skills by a bot ("chore: auto-sync skills directory from dart-lang/skills", most recently #241 on 2026-09-25). — [commit history](https://github.com/flutter/agent-plugins/commits/main)

**Rules**
- `rules/` contains exactly one rule, in two formats: `flutter-hot-reload.md` and `flutter-hot-reload.mdc` (about 1.2 KB each). Frontmatter is `trigger: glob`, `globs: "**/lib/**/*.dart"`. It tells the agent to discover running apps with the `dtd` MCP tool (or `list_running_apps` / `vm_service`), call `hot_reload` after UI or simple-method edits, and call `hot_restart` after changes to `initState`, globals or statics, or `main()`. It skips edits outside `lib/` and edits that only touch comments. The rule was added 2026-08-05 (#210) and updated 2026-09-02 (#228). — [rules/](https://github.com/flutter/agent-plugins/tree/main/rules)
- The Claude Code and Codex plugins do not auto-load rules. Users must paste them into CLAUDE.md, `.agent/rules/` or CODEX.md, and Cursor users copy `.mdc` files into `.cursor/rules/`. — [Get started with AI](https://docs.flutter.dev/ai/get-started); tracked as a documentation gap in [dart-lang/ai #649](https://github.com/dart-lang/ai/issues/649)

**Hooks (only in the `.agents/` manifest)**
- `.agents/hooks.json` defines two `Stop` hooks: `dart-format` (timeout 30 s) and `dart-analyze` (timeout 90 s). Both run Dart scripts in `tool/dart_hooks/bin/`. — [.agents/hooks.json](https://github.com/flutter/agent-plugins/blob/main/.agents/hooks.json)
- `.agents/agents/` contains `bare-agent` and `reidbaker-agent`. These look like internal or example agent definitions. It does not contain the a11y agent. — [.agents/agents](https://github.com/flutter/agent-plugins/tree/main/.agents)

**Distribution and installation**
- **Claude Code:** `.claude-plugin/plugin.json` sets name `dart-flutter`, version 1.0.6 and `mcpServers.dart-mcp-server = dart mcp-server` with env `AGENT_PLUGIN=claude-code`. `marketplace.json` names the marketplace `dart-flutter`. Install with `claude plugin marketplace add flutter/agent-plugins`, then `claude plugin install dart-flutter@dart-flutter`. — [.claude-plugin/plugin.json](https://github.com/flutter/agent-plugins/blob/main/.claude-plugin/plugin.json); [Get started](https://docs.flutter.dev/ai/get-started)
- **Codex:** `.codex-plugin/plugin.json` (v1.0.6, `"skills": "./skills/"`, MCP env `AGENT_PLUGIN=codex`). Install with `codex plugin marketplace add flutter/agent-plugins` and `codex plugin add dart-flutter@dart-flutter`. — [.codex-plugin/plugin.json](https://github.com/flutter/agent-plugins/blob/main/.codex-plugin/plugin.json); [Get started](https://docs.flutter.dev/ai/get-started)
- **Cursor:** available on the Cursor Marketplace (`cursor.com/marketplace/flutter`), or via `/add-plugin dart-flutter`. — [Get started](https://docs.flutter.dev/ai/get-started)
- **Antigravity IDE:** Settings → Customizations → "Build with Google Plugins" → download "Dart and Flutter". **Antigravity CLI (`agy`):** configure the MCP server manually in `.agents/mcp_config.json` and install skills with `npx skills add`. — [Get started](https://docs.flutter.dev/ai/get-started)
- **GitHub Copilot and others (Windsurf, Zed, Cline):** manual setup, using an MCP JSON entry plus `npx skills add flutter/agent-plugins --skill '*' --agent universal --yes` and `npx skills add dart-lang/skills ...`. — [Get started](https://docs.flutter.dev/ai/get-started)
- An open issue plans to move skills management from `npx skills` to the native Dart `skills` package. — [#203](https://github.com/flutter/agent-plugins/issues/203)
- The `package:skills` CLI suggests `flutter/agent-plugins` and `dart-lang/skills` as skill sources: dart-lang/skills always, flutter/agent-plugins when the project uses Flutter. — [get_skills.dart](https://github.com/dart-lang/ai/blob/main/pkgs/skills/lib/src/commands/get_skills.dart)

**Update cadence**
- From Aug to Sep 2026, commits were mostly tooling: the skills-lint migration, the sync bot, version bumps in the plugin manifests, the hot-reload rule, and an MCP env var (#238, 2026-09-17). No Flutter skill content has changed since 2026-04-21, based on each skill's `last_modified`. The repo has no GitHub releases apart from a linter tag (`dart_skills_lint-v0.4.0`, 2026-06-18). — [commits](https://github.com/flutter/agent-plugins/commits/main)

**Open issues and PRs (selection)** — [issues](https://github.com/flutter/agent-plugins/issues)
- #239 (2026-09-18) is a **bug**. `flutter-setup-localization` writes `synthetic-package: true` and imports `package:flutter_gen/...`, which fails on Flutter 3.47.2 stable because synthetic packages have been removed.
- #125 (P1): users see a "High Risk" alert before installing `flutter-use-http-package`.
- #101 (P1, 2026-04-29) is the "Accessibility skill" request. It says a11y tooling is being built and must be made available to agents, and it references an internal Google MCP a11y tooling doc.
- #88 (P1) is the **skill roadmap**. It proposes imperative navigation; install on macOS, Windows and Linux; explicit and implicit animation; `flutter-migrate-to-material3-theme`; file persistence; isolates; plugin init; federated plugins; Pigeon channels; FFI; Android, iOS and web native views; add-to-app on iOS and Android; json_serializable; state restoration; validating deep links; home-screen widgets; asset-size audit; and Android engine caching. None of these has shipped.
- #36 (P1) asks for a "create new project" skill. The MCP `create_project` tool is being disabled, and the team says the Gemini CLI extension already covers this, so work needs deduplicating.
- #198 asks for platform-specific or on-demand skills. An iOS plugin-migration skill (PR #191) was closed so that it would not load for every user.
- Other open items: #237, a WIP experiment for a `flutter-convert-to-flutter` skill (migration from native Android and iOS); #230, a `flutter-app-runtime` skill for runtime-inspection MCP tools; #202, a license move to Apache 2.0; #42, prompting users when their skills are stale; #37, unclear how to add more skills after initialization; #109 and #108, community ideas for bottom-sheet and MVVM-feature skills.
- A contributor warns against "skill bloat" and overlap causing "context hallucinations". — [#36 comment, 2026-04-22](https://github.com/flutter/agent-plugins/issues/36)

**Scope statement**
- Explicit scope: "happy path Flutter development" (README). The blog explains that doc-only skills added little value, so the team "pivoted to creating Skills that are 'task-oriented'", and the initial set was chosen through "extensive manual evaluations". — [Introducing Skills blog](https://blog.flutter.dev/introducing-skills-for-dart-and-flutter)
- docs.flutter.dev says the Flutter skills repo covers "widget construction, declarative navigation, responsive design, and **state management**". The only state-related content is ChangeNotifier-based MVVM inside the architecture skill. — [How Flutter AI tools work](https://docs.flutter.dev/ai/tools) vs. [skills/](https://github.com/flutter/agent-plugins/tree/main/skills)

### Inferences
- Coverage gaps, confirmed by keyword scans of all 25 SKILL.md files. There is no skill for:
  - Gradle, AGP, Kotlin, minSdk, compileSdk or NDK configuration (only one mention, `./gradlew` inside the integration-test skill)
  - iOS Podfile, Xcode, Swift Package Manager or signing (only an `Info.plist` deep-link step)
  - flavors, release builds, code signing, store upload or CI/CD
  - theming or design systems (Material 3 migration is only a roadmap item)
  - Riverpod, Bloc or other state libraries
  - accessibility
  - animation, performance profiling, platform channels or Pigeon
  - Firebase (Firebase publishes its own skills)
  - app creation or scaffolding
  - dependency upgrades
  - build_runner or json_serializable (Dart roadmap only)
- The integration-test skill tells the agent to call `launch_app` via MCP, but `launch_app` has been disabled by default in the MCP server since 0.1.3. The skill may fail unless the harness passes `--enable flutter_app_lifecycle`. A harness should set that flag or patch the step.
- Skill content appears to lag the SDK (see the #239 localization breakage), so a harness should pin versions and test them against the current stable Flutter.
- The plugin does not accept external PRs, so FlutterCraft's gap-filling skills would have to live in its own repo or be shipped as package skills.

### Gaps
- I could not verify the Cursor marketplace listing contents or install counts.
- I did not open the full `resources/flutter_skills.yaml` (38 KB). It appears to be the generator config for the 10 Flutter skills, holding the prompts and specs used to generate them.
- I found no published eval results. FlutterBench says "Coming soon" (see question 8).

## 2. dart-lang/skills: skills, distribution, cadence, issues, scope

### Takeaway
The repo holds 15 official Dart skills: testing, coverage, mocks, static analysis, dependency conflicts, runtime errors, FFI and native assets, ffigen, path, pattern matching, primary constructors, CLI apps, and documentation. The skill content is actively maintained (new or updated skills landed Jul–Sep 2026), and the skills are synced into the Flutter plugin. They are generic Dart and do not address Flutter app concerns.

### Cited Findings
- README: "Agent skills for Dart, maintained by the Dart team." Install with `npx skills add dart-lang/skills --skill '*' --agent universal --yes`; update with `npx skills update`. — [dart-lang/skills](https://github.com/dart-lang/skills)
- Repo stats: created 2026-02-25, last push 2026-09-24, 506 stars, 9 open issues/PRs, BSD-3-Clause. — [GitHub API](https://github.com/dart-lang/skills)
- The 15 skills: `dart-add-unit-test`, `dart-build-cli-app`, `dart-collect-coverage`, `dart-fix-runtime-errors` (uses hot reload verification), `dart-generate-test-mocks` (mockito), `dart-migrate-to-checks-package`, `dart-resolve-package-conflicts`, `dart-run-static-analysis` (`dart analyze` plus `dart fix`), `dart-setup-ffi-assets` (native-assets hooks for C/C++), `dart-use-doc-examples` (`{@example}`), `dart-use-ffigen`, `dart-use-path-package`, `dart-use-pattern-matching`, `dart-use-primary-constructors`, `dart-write-documentation`. Sizes range from about 4.7 KB to 19 KB (`dart-migrate-to-checks-package` is 19.3 KB; `dart-setup-ffi-assets` is 18.9 KB). — [skills/](https://github.com/dart-lang/skills/tree/main/skills)
- Recent commits:
  - 2026-09-24 path and pattern fixes (#49)
  - 2026-09-10 new `dart-use-path-package` (#44), CLI-app modernization (#38), pattern-matching anti-patterns (#40), CI running format and analyze on skills (#42)
  - 2026-08-24 doc-examples skill (#39)
  - 2026-08-20 API documentation skill (#37)
  - 2026-07-10 primary constructors (#32)
  - 2026-06-09 "Interop skills" (#28)
  - 2026-05-27 "Remove MCP tools section from SKILL.md" (#27)
  — [commits](https://github.com/dart-lang/skills/commits/main)
- Open issues:
  - #45: add explicit "When NOT to use" abstention guardrails across skills
  - #46: an unmatched quote in a checks-migration example
  - #36: "High Risk" install alert on `dart-setup-ffi-assets`
  - #26: "LLM says there are issues with dart-fix-runtime-errors and dart-collect-coverage"
  - #20: draft to turn coverage into a deterministic script
  - #12: idea for a `dart-run-quality-pipeline` skill
  — [issues](https://github.com/dart-lang/skills/issues)
- Roadmap issue #9 (last updated 04/24/2026) proposes at P1: `dart-update-pub-dependencies`, `dart-configure-build-runner`, `dart-run-build-runner`, `dart-compile-native-executable`, `dart-compile-web-js`, `dart-compile-web-wasm`, `dart-implement-js-interop`, `dart-serve-web-app`. At P2 it proposes records, class modifiers and dot shorthands. — [#9](https://github.com/dart-lang/skills/issues/9)
- Skill linting uses the published `skills_lint` package (0.5.2, 2026-09-18). — [pub.dev skills_lint](https://pub.dev/packages/skills_lint)

### Inferences
- The build_runner, codegen and pub-upgrade skills on the roadmap are exactly what Flutter apps need daily, and they are still missing. A harness could fill that gap now.
- The dart-lang skills are the better-maintained half: new skills land monthly, whereas the Flutter skills are frozen at April content.

### Gaps
- I did not read each Dart SKILL.md in full. Depth is inferred from file sizes and titles.

## 3. Dart & Flutter MCP server (`dart mcp-server`, dart-lang/ai/pkgs/dart_mcp_server)

### Takeaway
The server is at version 1.1.2 (pub, 2026-09-18, Dart SDK ^3.12.0). Since 1.0.0 it ships on pub, and `dart mcp-server` is an alias for `dart run dart_mcp_server@`. The README still labels it "WIP... experimental". It uses the stdio transport and offers about 24 tools. Many CLI-equivalent tools, including format, fix, create, run_tests and the whole app-lifecycle group, are **disabled by default** and must be enabled with `--enable`. It has no Gradle, Xcode, build or release tooling.

### Cited Findings
**Version and requirements**
- Latest version 1.1.2, published 2026-09-18, `environment.sdk: ^3.12.0`. — [pub.dev API: dart_mcp_server](https://pub.dev/packages/dart_mcp_server)
- 1.0.0 changelog: "Package is now shipped on pub instead of through the SDK. The `dart mcp-server` command will continue to work as an alias for `dart run dart_mcp_server@`." It also added `DART_ROOT` support, made the roots fallback always on, and enabled analytics via the `DASH__TOOL` env var. — [CHANGELOG](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/CHANGELOG.md)
- README: "Status: WIP. This package is still experimental and is likely to evolve quickly." Its setup notes say they "require Dart 3.9.0-163.0.dev or later". — [README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
- Client requirements: any stdio MCP client, which must support Tools and Resources and should support Roots. — [README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)

**Tool table (from the README's generated section; "Enabled" is the default state)** — [README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
- **Enabled by default**
  - Analysis and code intelligence: `analyze_files` (analyze paths or the whole project; supports auto-fix of diagnostics; compact output); `lsp` (hover, signatureHelp, resolveWorkspaceSymbol).
  - Live app connection: `dtd` (listDtdUris, connect, listConnectedApps); `vm_service` (connect by VM service URI, invoke raw VM service methods).
  - Running app: `get_runtime_errors`; `hot_reload`; `hot_restart`; `widget_inspector` (widget tree, selected widget, selection mode); `flutter_driver_command` (tap, enter_text, screenshot, set_frame_sync, set_semantics, and more).
  - Packages: `pub` (pub get/add/remove); `pub_dev_search` (downloads, description, topics, license, publisher); `read_package_uris` (`package:` and `package-root:` URIs); `rip_grep_packages` (needs ripgrep installed).
  - `roots`.
- **Disabled by default**
  - CLI category: `create_project`, `dart_fix`, `dart_format`, `run_tests`.
  - `get_active_location`.
  - flutter_app_lifecycle category: `launch_app`, `list_devices`, `list_running_apps`, `get_app_logs`, `stop_app`.
- Rationale in the 0.1.3 changelog: "Disable all tools that can easily be done on the CLI by default... re-enabled by passing `--enable cli` or `--enable <tool-name>`." It also says: "Agents tend to do better just using the CLI to manage the app lifecycle." `--disable` or `--enable` by category or name replaces the deprecated `--tools` and `--exclude-tool` flags. `launch_app` gained `args` for `--flavor` and `--dart-define`. — [CHANGELOG 0.1.3 (Dart SDK 3.12.0)](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/CHANGELOG.md)
- Recent changes:
  - 1.1.0: `vm_service` meta tool; "Harden various tools against compromised agents"; analysis requests now block until complete.
  - 1.1.1: server instructions "encourage agents to proactively connect to running applications and hot reload".
  - 1.1.2: `create` tool fixes; the `AGENT_PLUGIN` env var is tracked in analytics.
  — [CHANGELOG](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/CHANGELOG.md)
- **"Agentic Hot Reload"** launched with Flutter 3.44 (May 2026). The MCP server "will now automatically find and connect to running Dart and Flutter applications". The same release announced "Hardened dependency search" and "Consolidated tools... significantly reducing token costs". — [What's new in Flutter 3.44 (2026-05-20)](https://blog.flutter.dev/whats-new-in-flutter-3-44)
- Connecting to apps:
  - Flutter debug and profile apps register with DTD automatically, unless `--no-dds` is used.
  - Pure Dart apps need `--observe`.
  - `--print-dtd` gives an explicit DTD URI, and the README recommends putting this instruction in a rules file.
  — [README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
- Per-client setup in the README covers Gemini CLI, Gemini Code Assist, Cursor (deeplink) and GitHub Copilot (`"dart.mcpServer": true` in Dart-Code ≥ v3.114). Android Studio support is still a TODO, with open issue #575 "Ensure MCP works in Android studio". — [README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server); [#575](https://github.com/dart-lang/ai/issues/575)
- The standalone docs page `docs.flutter.dev/ai/mcp-server`, and `dart.dev/tools/mcp-server` which redirected to it, now 301-redirect to `/ai/get-started`. — [flutter/website firebase.json redirects](https://github.com/flutter/website)

**Open issues (dart-lang/ai has 82 open in total)** — [issues](https://github.com/dart-lang/ai/issues)
- #692 (2026-09-25): wrong image-format index in the screenshot code
- #668: update to MCP spec version 2026-07-28
- #651: `flutter_driver_command` description unclear
- #591: add an `emulator` command
- #535: API discovery across project, SDK and deps
- #532: "Investigate increasing number of cursor errors"
- #498: improve hot-reload tool discovery
- #476: debugging CUJs with the raw VM service
- #461: a skills command inside the MCP server
- #450: ship a skill teaching optimal MCP usage
- #448: umbrella "frictionless UX for the Dart MCP server"
- #446: audit tool descriptions
- #650 (P1): a `dart-setup-mcp` agent skill
- #647 (P1): a `flutter-app-runtime` skill
- **Windows:** a search for open issues mentioning Windows returned only #151 (2025-06-02, "Windows test for errors resource failing"). — [#151](https://github.com/dart-lang/ai/issues/151)

### Inferences
- Default-disabled tools matter for a harness. If FlutterCraft wants agents to run tests or launch apps through MCP, it has to pass `--enable cli` and/or `--enable flutter_app_lifecycle` in the MCP config it writes. The official plugin manifests pass no flags.
- The server's own changelog shows the team thinks agents should use the shell for the app lifecycle. A harness therefore still needs its own robust `flutter run` management: device selection, the `--print-dtd` capture, log tailing and process cleanup. This fits a TUI harness well.
- Areas with no MCP tool at all:
  - native build configuration (Gradle, AGP, Xcode, CocoaPods, SPM)
  - `flutter build` and release artifacts
  - `flutter doctor` and environment diagnosis
  - FVM or SDK version management
  - emulator management (only requested, #591)
  - DevTools performance and memory profiling beyond raw vm_service calls
  - codegen (build_runner)
- There is little public evidence of Windows-specific breakage, but the absence of issues is not proof. FlutterCraft should test on Windows itself.

### Gaps
- I found no official statement of a guaranteed minimum Flutter SDK for 1.1.2. When invoked through the SDK alias, it is resolved via `dart run`, which needs a Dart SDK that satisfies ^3.12.0 (Flutter 3.44+ bundles Dart 3.12, per the I/O coverage). Mapping Flutter versions to Dart versions beyond that is inference.
- I did not enumerate all 82 open dart-lang/ai issues. The list above is the ~40 most recent non-PR issues.

## 4. Google Developer Knowledge MCP server

### Takeaway
This is a Google-hosted remote MCP server (`https://developerknowledge.googleapis.com/mcp`) with 3 tools. It covers 24 Google doc domains, including docs.flutter.dev and dart.dev but apparently not api.flutter.dev, api.dart.dev or pub.dev. It needs a Google Cloud project with the Developer Knowledge API enabled, plus an API key, OAuth or ADC. Content is English-only and public-only, with a goal of re-indexing within about 48 hours.

### Cited Findings
- Endpoint `https://developerknowledge.googleapis.com/mcp`. Tools: `search_documents` (page excerpts), `get_documents` (full Markdown by document name), `answer_query` (structured answers generated from the corpus). — [Developer Knowledge MCP (updated 2026-09-25)](https://developers.google.com/knowledge/mcp)
- Auth options: API key via the `X-Goog-Api-Key` header (third-party IDEs and CLI agents), OAuth 2.0 (Desktop app type), or ADC (Antigravity and enterprise). The Developer Knowledge API must be enabled in a Google Cloud project. Quotas are visible under IAM & Admin → Quotas, and a `429 RESOURCE_EXHAUSTED` error is documented. The page lists no pricing or quota numbers. — [Developer Knowledge MCP](https://developers.google.com/knowledge/mcp)
- Limitations: "English language" only; public documentation only; needs network access; not supported behind VPC Service Controls. Listed supported clients include Antigravity, Claude Code, Cursor, Copilot, Codex, JetBrains AI Assistant, Windsurf, Cline, Zed, Continue and Claude Desktop. — [Developer Knowledge MCP](https://developers.google.com/knowledge/mcp)
- The corpus spans 24 domains, including adk.dev, ai.google.dev, antigravity.google, cloud.google.com, **dart.dev**, developer.android.com, firebase.google.com, **docs.flutter.dev**, geminicli.com, genkit.dev, go.dev and web.dev. Freshness: "Our goal is to re-index content within 48 hours of publication." — [Corpus reference (updated 2026-09-25)](https://developers.google.com/knowledge/reference/corpus-reference)
- Flutter docs position it as the "cloud-hosted documentation search server" for "live docs, API references". — [How Flutter AI tools work](https://docs.flutter.dev/ai/tools)

### Inferences
- The WebFetch summary did not show api.flutter.dev, api.dart.dev or pub.dev in the domain list. If that is right, API-reference lookups for specific packages still depend on the local MCP tools `read_package_uris`, `rip_grep_packages` and `lsp`, which read the actual dependency source, and on `pub_dev_search`.
- The Google Cloud project and API key step adds onboarding friction. A harness can automate or guide it but cannot remove it.

### Gaps
- I found no pricing or free-tier quota numbers. The page says only that quotas exist.
- The WebFetch summary listed about 20 domain names while saying there were 24, so the exact domain list should be re-verified.

## 5. Package skills (`package:skills`, `dart run skills@ get`)

### Takeaway
`package:skills` (1.0.1 on pub, 2026-09-04; 1.0.2 exists in the repo changelog) is the official Dart CLI. It finds `skills/` directories in pubspec dependencies and copies them into each agent's skills folder: Claude, Codex, Cursor, Copilot, Cline, OpenCode, Antigravity and generic. It also installs skills from git repos as an `npx skills` replacement. Among the major packages I checked, only Serverpod (21 skills) and genui (2) ship skills. The mechanism is stable at 1.0, but adoption is early.

### Cited Findings
- Commands: `get` (with `--all`, `-p <package>`, `-s <skill>`, `--git <repo>`), `list`, `prune` (runs automatically after `get`), `remove`, `add <git-url>`, `create` (scaffolds a skill for package authors). It runs `pub get` if needed and supports monorepos. — [pkgs/skills README](https://github.com/dart-lang/ai/tree/main/pkgs/skills)
- Agent install locations: Antigravity, Codex and generic use `.agents/skills/`; Claude uses `.claude/skills/`; Cline `.cline/skills/`; Cursor `.cursor/skills/`; Copilot `.github/skills/` (not auto-detected); OpenCode `.opencode/skills/`. The agent is auto-detected from directory markers, and `--agent` or `SKILLS_AGENT` overrides it. — [pkgs/skills README](https://github.com/dart-lang/ai/tree/main/pkgs/skills)
- Naming rule: skill directories must be prefixed with the package name (e.g. `serverpod-...`), and non-conforming skills are "silently skip[ped]". State is tracked in `.config/dart_skills`, which should be committed only if the agent directories are committed. — [pkgs/skills README](https://github.com/dart-lang/ai/tree/main/pkgs/skills)
- The dart.dev docs say it scans immediate dependencies and detects local modifications, prompting the user to overwrite or keep them. — [Package skills (dart.dev)](https://dart.dev/ai/package-skills) (source: [site-www](https://github.com/dart-lang/site-www/blob/main/src/content/ai/package-skills.md))
- Versions: 1.0.0-beta.1 through beta.4, then 1.0.0, 1.0.1 (pub, 2026-09-04, SDK ^3.10.0), and 1.0.2 in the repo changelog. — [CHANGELOG](https://github.com/dart-lang/ai/blob/main/pkgs/skills/CHANGELOG.md); [pub.dev API](https://pub.dev/packages/skills)
- On `get`, the CLI suggests adding `dart-lang/skills` and, for Flutter projects, `flutter/agent-plugins`, with an option to never ask again on the machine. — [get_skills.dart](https://github.com/dart-lang/ai/blob/main/pkgs/skills/lib/src/commands/get_skills.dart)
- **Adoption check (repo default branches, 2026-09-28)**
  - `serverpod/serverpod` `packages/serverpod/skills/` has 21 skills (auth, caching, configuration, database, deployment, endpoints, file-uploads, flutter-frontend, health-checks, logging, migrations, models, modules, overview, scheduling, server-events, sessions, streams, testing, upgrading, webserver).
  - `flutter/genui` `packages/genui/skills/` has `create-catalog-item` and `integrate-genui-firebase`.
  - No `skills/` directory at the checked package paths for riverpod, flutter_riverpod, bloc, flutter_bloc, go_router, dio, drift, freezed, firebase_core, shelf or solidart.
  — [serverpod skills](https://github.com/serverpod/serverpod/tree/main/packages/serverpod/skills); [genui skills](https://github.com/flutter/genui/tree/main/packages/genui/skills)
- Open issues show a lot is still immature:
  - #585: an agent hook to fetch skills after a pubspec change
  - #620: skills for global packages
  - #555: `validate` command
  - #556: author opt-in to auto-selection
  - #546: descriptions in dialogs
  - #608 and #609: an odd `skills_config.json` structure
  - #471: analyzer plugin warning about outdated skills
  — [dart-lang/ai issues](https://github.com/dart-lang/ai/issues)
- Firebase separately publishes "Firebase Agent Skills for Flutter" (announced with Flutter 3.44) in the `firebase/agent-skills` repo, last pushed 2026-09-25. — [What's new in Flutter 3.44](https://blog.flutter.dev/whats-new-in-flutter-3-44); [firebase/agent-skills](https://github.com/firebase/agent-skills)

### Inferences
- There is no auto-refresh when pubspec changes (that is #585, still open). A harness can add value by running `dart run skills@ get` whenever `pubspec.yaml` or `pubspec.lock` changes.
- The genui skill names (`create-catalog-item`) do not appear to follow the required `genui-` prefix convention, so they may be skipped when installed. I did not test this.
- Adoption among popular state-management, routing and networking packages appears to be near zero. Community or harness-supplied skills for Riverpod, Bloc, go_router, dio, drift and freezed are a clear gap.

### Gaps
- I found no official registry or count of packages that ship skills. pub.dev has no "has skills" filter that I could find.
- A package may ship `skills/` in its published archive at a different path than the repo directories I checked. I did not inspect pub archives directly.

## 6. Flutter Accessibility (a11y) agent

### Takeaway
The official "Flutter Accessibility (`@flutter_a11y_agent`)" specialized agent is documented as available **only in Google Antigravity**, bundled with the Antigravity "Dart and Flutter" plugin. It is not in the public flutter/agent-plugins repo. A copy that third parties extracted from Antigravity's bundled plugin shows it is a plain Markdown persona of about 5.5 KB with an Antigravity-specific tool list, so the prompt itself would work in other agents. That copy is not an official distribution.

### Cited Findings
- Official description: it audits widget trees for semantic labels, touch targets (48x48), contrast and focus indicators, and produces "Automated code fixes". It "is currently available in Google Antigravity" and is invoked via the agent picker or `@flutter_a11y_agent` after installing the Dart and Flutter plugin in Antigravity. — [How Flutter AI tools work](https://docs.flutter.dev/ai/tools)
- The public `flutter/agent-plugins` repo contains no a11y agent. `.agents/agents/` holds only `bare-agent` and `reidbaker-agent`. The a11y **skill** is an open P1 request (#101), which references an internal Google doc on MCP a11y tooling (go/flutter-mcp-accessibility-tooling). — [flutter/agent-plugins/.agents](https://github.com/flutter/agent-plugins/tree/main/.agents); [#101](https://github.com/flutter/agent-plugins/issues/101)
- **Third-party copy, not an official source.** `SamarthaKV29/antigravity-god-mode` hosts `plugins/flutter/agents/a11y_agent.md`, taken from an Antigravity Flutter plugin that reports version 1.0.5. The same bundle includes the same `flutter-hot-reload.md` rule and the same skills as flutter/agent-plugins.
  - Frontmatter: `name: flutter_a11y_agent`, `disabled: true`, `mainAgent: true`, `subagent: true`, `commandExecutionPolicy: auto`, with Antigravity tools (`find_by_name`, `grep_search`, `view_file`, `list_dir`, `read_url_content`, `search_web`, `schedule`, `generate_image`, `send_message`).
  - Body checklist:
    1. Semantics: labels, traits, MergeSemantics and ExcludeSemantics, and live regions instead of `SemanticsService.announce`.
    2. Tap targets: 48x48 on Android, 44x44 on iOS and web.
    3. WCAG contrast of 4.5:1 or 3:1 in light and dark themes; no color-only information.
    4. Text scaling: no hardcoded heights, no forcing `textScaleFactor`.
    5. Focus and keyboard navigation: `FocusTraversalGroup`/`FocusTraversalOrder`.
    6. Automated tests with `meetsGuideline(textContrastGuideline | androidTapTargetGuideline | iOSTapTargetGuideline | labeledTapTargetGuideline)`.
  - Operation: review `git diff` or PRs, categorize severity, and propose fixes.
  — [third-party copy](https://github.com/SamarthaKV29/antigravity-god-mode/blob/main/plugins/flutter/agents/a11y_agent.md)
- Code search also found similar `a11y_agent.md` copies in other personal repos, for example a `.cursor/agents/a11y_agent.md`. — GitHub code search for `flutter_a11y_agent` (2026-09-28)

### Inferences
- The agent is only a prompt plus the model's built-in file and search tools. It uses no special MCP a11y tooling, because that tooling is still being built (#101). Porting its checklist to Claude Code or Codex subagents would be simple. However, the official text is not published under a license in a public Google repo, so FlutterCraft should write its own a11y agent informed by the documented capabilities rather than copy the extracted file.
- The official doc's claim of "contrast checks" is static-code reasoning only. Runtime semantics-tree auditing would need the MCP `widget_inspector` or `flutter_driver set_semantics`, which the persona does not use.

### Gaps
- I found no official public source file or license for the a11y agent, and no statement about bringing it to Claude Code, Codex or Cursor.
- It is unclear why the extracted copy has `disabled: true`. It might be disabled by default in Antigravity and enabled by the plugin, but this is unverified.

## 7. Official Flutter AI rules files (rules.md / rules_10k / rules_4k / rules_1k)

### Takeaway
**These have been removed and replaced.** The monolithic rules files that used to live in `flutter/flutter/docs/rules` (rules.md plus the 10k, 4k and 1k size variants) are gone. That directory now holds only a README saying Flutter provides guidance "through agent plugins and skills... instead of a single, static set of rules". `docs.flutter.dev/ai/ai-rules` 301-redirects to `/ai/get-started`. The only official "rule" today is the `flutter-hot-reload` rule in flutter/agent-plugins.

### Cited Findings
- `flutter/flutter/docs/rules/README.md`: "This directory no longer contains rule files for AI coding assistants. Flutter now provides similar guidance through agent plugins and skills, which give your assistant focused instructions for the task at hand instead of a single, static set of rules. If your assistant's configuration references one of the removed rule files, remove that reference..." — [flutter/flutter docs/rules](https://github.com/flutter/flutter/tree/master/docs/rules)
- Redirects in the docs site config: `/ai/ai-rules` → `/ai/get-started`, `/ai/mcp-server` → `/ai/get-started`, `/ai/gemini-cli-extension` and `/ai/flutter-ext-for-gemini` → `/ai/get-started`, `/ai/agent-skills` → `/ai/get-started`, `/ai/evals` → `/ai/tools`. — [flutter/website sites/docs/firebase.json](https://github.com/flutter/website)
- The current rules directory contains only `flutter-hot-reload.md` and `.mdc` (see question 1). — [agent-plugins/rules](https://github.com/flutter/agent-plugins/tree/main/rules)
- A WebFetch of `docs.flutter.dev/ai/ai-rules` (redirected) summarized the page as mentioning "rules.md, rules_10k, rules_4k, rules_1k" variants. The actual page source ([get-started.md](https://github.com/flutter/website/blob/main/sites/docs/src/content/ai/get-started.md)) contains no such text. I treat that summary as a hallucination by the fetch model and **discard it**.

### Inferences
- Any FlutterCraft design that planned to install `rules_4k.md` and similar files should drop that plan. The official direction is skills plus a minimal glob rule. If a compact always-on Flutter rules file is wanted (for example Dart style, null-safety or `const` conventions), FlutterCraft would have to author it, or pull from older copies with an explicit "deprecated upstream" flag.

### Gaps
- I did not retrieve the historical content of the removed rules files or the exact removal date from git history. Commit archaeology on `flutter/flutter/docs/rules` would settle this.

## 8. Team statements, blog posts, roadmap (2025–2026), GenUI / AI Toolkit / Antigravity / Gemini CLI / evals

### Takeaway
The official strategy is "agent-agnostic via open standards (MCP, Agent Skills)", with first-party priority on Antigravity and Gemini CLI. The main shipped items are Agent Skills (May 2026), Agentic Hot Reload (Flutter 3.44, May 2026), the plugin packaging for Claude Code, Codex, Cursor and Antigravity, and package skills (1.0 around Sep 2026). App-side AI (GenUI/A2UI, Firebase AI Logic, Genkit Dart, the AI Toolkit) is a separate track. An automated eval pipeline (FlutterBench, `flutter/evals`) is announced but its results are not published.

### Cited Findings
- **2026 roadmap (flutter/flutter docs/roadmap):** "AI-reimagined developer experience... collaborate within Google to ensure Dart and Flutter have top-tier support in Gemini CLI and Antigravity, ensuring core workflows like stateful hot reload work seamlessly with AI agents. We are also investing in MCP servers for Dart tooling, enabling AI agents to perform complex refactors and choose secure, performant libraries." Other items: GenUI and A2UI, Dart interpreted bytecode for dynamic UIs, Dart Cloud Functions, Genkit Dart, and decoupling Material and Cupertino. — [Roadmap.md](https://github.com/flutter/flutter/blob/master/docs/roadmap/Roadmap.md); [Flutter & Dart's 2026 roadmap blog (2026-02-24)](https://blog.flutter.dev/flutter-darts-2026-roadmap)
- **"How Dart and Flutter are thinking about AI in 2026" (2026-04-01):**
  - 79% of Flutter developers use AI assistants (2025 Flutter user survey).
  - Three target personas: traditional, AI-assisted and AI-first.
  - Principles: "Humans first", "Add, don't replace", "Open standards & agent agnostic... Flutter works well with any agent you choose, not just Gemini", and "Trust through quality" (reducing the "verification tax", with evals alongside DeepMind and Antigravity).
  - Framed as "less of a roadmap and more of a collection of thoughts".
  — [blog](https://blog.flutter.dev/how-dart-and-flutter-are-thinking-about-ai-in-2026)
- **Flutter 3.44 / Dart 3.12 at Google I/O 2026 (2026-05-20):** "Agentic Hot Reload" (the MCP server auto-discovers running apps), hardened dependency search, consolidated MCP tools, and Agent Skills. It also announced Firebase Agent Skills for Flutter, Firebase AI Logic server prompt templates, the Genkit Dart preview, LiteRT-LM for Flutter, and GenUI + A2UI (genui downloads "up 500%"). — [What's new in Flutter 3.44](https://blog.flutter.dev/whats-new-in-flutter-3-44); I/O recap: [That's a wrap: Flutter at Google I/O 2026 (2026-05-28)](https://flutter.dev/blog/thats-a-wrap-everything-flutter-at-google-i-o-2026)
- **Flutter 3.47 (2026-08-12):** Widget Previews graduate to stable. genui 0.10.0 introduces the `a2ui_core` package and A2UI client-side functions. The release has no new agent-tooling announcements. — [What's new in Flutter 3.47](https://blog.flutter.dev/whats-new-in-flutter-3-47)
- Docs page "Get started with AI" was last updated 2026-09-14 and references Flutter 3.47. It frames the plugin as four capabilities: skills, rules, the MCP server and specialized agents. — [Get started](https://docs.flutter.dev/ai/get-started) (the date comes from WebFetch page metadata)
- **"Flutter's multiplatform value for agentic development" (2026-05-18):** argues that a single codebase means fewer tokens, strong typing and MCP act as a self-correcting loop, and hot reload gives fast validation. — [blog](https://blog.flutter.dev/flutters-multiplatform-value-for-agentic-development)
- **"Building multi-agent development teams" (2026-08-20):** a DevRel experiment using Antigravity's Agent Hub. An Architect, testers and coders, each defined as a role skill, ran TDD to port Python libraries to Dart, with write-scope restrictions per role. It is an example workflow, not a product. — [blog](https://blog.flutter.dev/building-multi-agent-dev-teams)
- **Flutter extension for Gemini CLI:** `gemini-cli-extensions/flutter` is labeled "Status: Experimental". It covers project bootstrapping, guided modifications with planning and git branches, pre-commit format, analyze and test, commit messages, and context priming. It was last pushed 2026-03-02 (dormant for about 7 months), and its docs page now redirects to `/ai/get-started`. — [gemini-cli-extensions/flutter](https://github.com/gemini-cli-extensions/flutter)
- **Evals:** `docs.flutter.dev/ai/flutter-bench` says "Evaluation tooling and benchmarks are coming soon". A CUJ catalogue page (noindex) lists CUJs used to derive FlutterBench tasks. `flutter/evals` ("highly unstable", built on Inspect AI, last pushed 2026-08-01, 21 stars) contains a Python runner, the `devals` CLI and an eval explorer. — [flutter-bench source](https://github.com/flutter/website/tree/main/sites/docs/src/content/ai/flutter-bench); [flutter/evals](https://github.com/flutter/evals)
- The **AI Toolkit** docs (`/ai/ai-toolkit`: chat client, custom LLM providers, feature integration) and **GenUI** docs (`/ai/genui`) remain under docs.flutter.dev/ai. These are app-side AI features, not developer agent tooling. — [flutter/website ai/](https://github.com/flutter/website/tree/main/sites/docs/src/content/ai)

### Inferences
- The strategic direction is clear. Rules have been collapsed into skills, the MCP server is slimmed to "what the CLI can't do", and everything is packaged as per-agent plugins. Google's first-class surface is Antigravity, which has the extra a11y agent and one-click install. Parity for Claude Code and Codex is decent for skills and MCP but weaker for rules and agents.
- There is no official Google plan (roadmap item or issue) for native build configuration, release pipelines, store deployment, or design-system/theming agents. The only related items are the proposed "install on macOS/Windows/Linux" and Material 3 theme skills in #88. These remain open gaps for FlutterCraft to fill.
- Because eval results (FlutterBench) are unpublished, there is no public quality evidence for the official skills. FlutterCraft could run its own evals, possibly on `flutter/evals`.

### Gaps
- I could not confirm an official Antigravity page listing everything the Antigravity "Dart and Flutter" plugin contains beyond the skills, MCP, rule and a11y agent.
- I found no Dart-blog (medium.com/dartlang or dart.dev/blog) post dedicated to package skills. The Dart 3.12 announcement exists ([dart.dev/blog/announcing-dart-3-12](https://dart.dev/blog/announcing-dart-3-12)) but I did not read it.
- Firebase Studio's Flutter AI integration (blog "Unleash new AI capabilities for Flutter in Firebase Studio" exists in the blog index) was not examined.
