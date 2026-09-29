# Competitive Landscape: Flutter AI App-Building Tools and Multi-Agent Coding Harnesses (as of 28 Sept 2026)

Research date: 2026-09-28. GitHub star, fork and version figures were read from the live repo pages on that date unless noted. "Verified" means taken from the product's own site, repo or docs. Third-party review or SEO blogs are marked as secondary.

---

## Q1. Flutter-specific AI builders and tools: what they produce, and what users complain about

### Takeaway
The Flutter AI tooling space has split into two layers:
1. **Hosted prompt-to-app builders.** Dreamflow/FlutterFlow, Rocket and FlutterAIDev sell to beginners and vibe coders on credit-based subscriptions.
2. **Free, official or open-source "agent enhancers".** Google's Dart & Flutter MCP server, `flutter/agent-plugins` skills, VGV's AI plugin and Arenukvern's `mcp_flutter` plug into Claude Code, Codex, Cursor and Antigravity.

Nobody packages layer 2 into a turnkey, opinionated harness. The recurring complaints are that agents produce stale APIs, off-convention architecture and prototype-grade (not production) output.

### Cited Findings

**Official Google / Flutter-team tooling**
- Official Flutter docs (as of 2026-09-14, referencing Flutter 3.47) point to two skills repos:
  - `flutter/agent-plugins` for Flutter skills and rules
  - `dart-lang/skills` for Dart skills
  - Install commands for Claude Code: `claude plugin marketplace add flutter/agent-plugins` and `claude plugin install dart-flutter@dart-flutter`
  - The docs also cover Cursor (`/add-plugin dart-flutter`), Codex (`codex plugin marketplace add flutter/agent-plugins`), GitHub Copilot (`npx skills add ...`) and Antigravity (GUI install, or `agy` CLI with `.agents/mcp_config.json`)
  - Rules go into CLAUDE.md, `.cursor/rules/*.mdc`, `copilot-instructions.md` or CODEX.md
  - — [Flutter docs: Agent skills](https://docs.flutter.dev/ai/agent-skills)
- The official skills are "on-demand procedural guides" covering:
  - layout errors, widget previews, widget tests and integration tests
  - responsive layouts, layered architecture and routing
  - localization, JSON serialization and HTTP requests

  The Claude Code plugin bundles the skills together with the Dart & Flutter MCP server config. — [Flutter docs: Agent skills](https://docs.flutter.dev/ai/agent-skills); [Flutter docs: Get started with AI](https://docs.flutter.dev/ai/get-started)
- The Dart & Flutter MCP server is started with `dart mcp-server` and lives in `dart-lang/ai/pkgs/dart_mcp_server`. Its tools can:
  - analyze and fix errors
  - resolve symbols and fetch docs and signatures
  - introspect and interact with the running app
  - search pub.dev
  - manage pubspec dependencies

  — [dart.dev MCP server](https://dart.dev/tools/mcp-server)
- **Antigravity 2.0 (Google I/O 2026)**, reported by a secondary source:
  - replaces Gemini CLI with a Go-based CLI called `agy`
  - adds an SDK for custom agent workflows
  - ships the Dart & Flutter MCP server, which gives agents live context of the running app

  — [DEV: Antigravity 2.0 for Flutter devs](https://dev.to/sayed_ali_alkamel/antigravity-20-for-flutter-developers-cli-sdk-agentic-workflows-that-actually-matter-231o) (secondary; the `agy` CLI is corroborated by the official docs' Antigravity install instructions, [Flutter docs](https://docs.flutter.dev/ai/agent-skills), and by Munder Difflin listing `agy` as a supported CLI, [munderdiffl.in](https://munderdiffl.in/))
- **Firebase Studio (formerly Project IDX) is being sunset:**
  - sunset announced 19 March 2026
  - no new workspaces from 22 June 2026
  - full shutdown on 22 March 2027
  - Google points code-first developers to Antigravity and prototypers to Google AI Studio

  — [Firebase: Studio sunset & migration](https://firebase.google.com/docs/studio/migrating-project); [Storyboard18](https://www.storyboard18.com/digital/google-to-shut-firebase-studio-in-2027-shifts-focus-to-ai-studio-and-antigravity-92922.htm)

**FlutterFlow / Dreamflow**
- Dreamflow bills itself as a "Visual AI Builder for Production Mobile Apps", "from the team behind FlutterFlow", and "trusted by 2M+ builders" (self-reported). Features:
  - tri-surface editing: AI prompt, visual canvas and code, kept in sync
  - OpenAI and Anthropic models
  - Firebase and Supabase integration
  - full Flutter project export

  — [dreamflow.app](https://dreamflow.app/)
- Dreamflow pricing (verified on its site):

  | Tier | Price | What you get |
  |---|---|---|
  | Free | $0 | 10 AI credits, web deploy |
  | Hobby | $20/mo | store deploy, full code export, 100 credits |
  | Pro | $90/mo | Git, 500 credits, premium model priority |
  | Enterprise | custom | BYOM |

  — [dreamflow.app](https://dreamflow.app/)
- Reviewers say Dreamflow's limits make it "more suitable for rapid prototyping rather than building fully-functional, production-ready apps". — [No Code MBA / search summary](https://www.nocode.mba/articles/dreamflow-flutterflow-ai) (secondary)
- FlutterFlow custom-code complaints (secondary):
  - custom code is a "compliance nightmare rather than an escape hatch"
  - FlutterFlow accepts Dart only in a very specific form, so its custom code "might as well be its own programming language"

  — [DEV: FlutterFlow's AI future is DreamFlow](https://dev.to/sgardoll/flutterflows-ai-future-is-dreamflow-its-ai-present-is-this-2cf1)
- **Unverified claim: "Google acquired FlutterFlow in late 2025".** It appears only in third-party SEO/review sites ([ortemtech](https://ortemtech.com/blog/flutterflow-review-2026-what-it-is-and-when-to-use-it/), [rationalgo.ai](https://rationalgo.ai/resources/compare/flutterflow-alternative)). I found no official FlutterFlow or Google announcement, and Dreamflow's own site does not mention Google. Treat it as UNVERIFIED and possibly hallucinated by AI-written SEO content.

**Very Good Ventures (VGV)**
- `VeryGoodOpenSource/very_good_ai_flutter_plugin` (MIT, 165 stars, 23 forks) is a Claude Code plugin.
- It has 14 skills:
  - Create Project, Animations (M3 motion), Accessibility (WCAG 2.2), Testing (unit/widget/golden)
  - GoRouter navigation, i18n/RTL, Material 3 theming, Bloc
  - Layered Architecture (VGV 4-layer), Security, UI Package, License Compliance
  - SDK upgrade, very_good_analysis upgrade, and a "Green Gate" autonomous quality-verification loop
- It adds one read-only "Flutter Reviewer" agent.
- It requires Very Good CLI v1.3.0 or later.
- — [GitHub: very_good_ai_flutter_plugin](https://github.com/VeryGoodOpenSource/very_good_ai_flutter_plugin)
- Very Good CLI 1.0 ships an MCP server (`very_good mcp`) for template-based project creation, tests with coverage enforcement, dependency management and license compliance. VGV recommends pairing it with the Dart MCP server in `.mcp.json`. — [VGV blog: Very Good CLI MCP server](https://verygood.ventures/blog/very-good-cli-mcp-server-flutter-ai-tools/); [VGV blog: Very Good CLI 1.0](https://verygood.ventures/blog/very-good-cli-1-0-flutter-testing-mcp-semantic-versioning/)

**Community MCP / harness tooling**
- `Arenukvern/mcp_flutter` ("flutter-mcp-toolkit"): MIT, 380 stars, 46 forks, 1,192 commits, v4 stable.
  - It explicitly calls itself an "agentic harness" built around a closed feedback loop.
  - Inspection: semantic snapshots, widget tree, error logs, screenshots, VM info.
  - Interaction: tap, type, scroll, hot reload, navigate, wait-for.
  - Apps can register their own MCP tools at runtime.
  - Supports Claude Code, Cursor, Codex, Cline and generic MCP clients.
  - It sets itself apart from the official server by focusing on dynamic in-app tools rather than Dart tooling.
  - — [GitHub: mcp_flutter](https://github.com/Arenukvern/mcp_flutter)

**Prompt-to-Flutter startups (2025–26)**
- FlutterAIDev (Product Hunt, 2026): describe an app, get Flutter code with a live preview, export an APK and source. — [Product Hunt](https://www.producthunt.com/products/flutteraidev)
- Rocket.new markets a "Flutter App Builder AI" that produces complete mobile apps with backend logic and exportable code (vendor marketing). — [Rocket blog](https://www.rocket.new/blog/flutter-app-builder-ai)
- Codemagic, the Flutter-first CI/CD service, has no evidence of its own AI agent product. AI integration appears through its REST API used by third-party agent platforms (Beam, Tars). — [Beam integration](https://beam.ai/integrations/codemagic); [Codemagic](https://codemagic.io/start/)

**Complaints about AI-written Flutter code**
- The author of "Vibe Coding a Flutter App with Claude Code" (28 Apr 2026) reports three problems:
  - one model "hallucinates Riverpod APIs from 2022"
  - another "forgets your folder conventions halfway through a refactor"
  - multi-file refactors break imports

  The fix they recommend is CLAUDE.md, MCP servers, skills and a single consistent model. — [ApparenceKit blog](https://apparencekit.dev/blog/vibe-coding-flutter-claude-code/)
- The Flutter APIs churn quickly, which fuels stale-API output: `withOpacity()` was deprecated in 3.27 in favor of `withValues()`, and Riverpod 3.0 changed APIs. — [Medium: withOpacity → withValues](https://hasan-hammoudah.medium.com/migrating-from-withopacity-to-withvalues-in-flutter-3-27-what-you-need-to-know-9d4f81d4adab); [Code with Andrea newsletter Sept 2025](https://codewithandrea.com/newsletter/september-2025/)

### Inferences
- Google has cleared out its own "cloud IDE" layer (Firebase Studio is dying) and is betting on Antigravity plus open MCP servers and skills. So the official Flutter AI path is now "bring your own agent CLI + official plugin". A harness that installs and orchestrates these automatically aligns with Google's direction instead of competing with it.
- VGV's plugin, the official `flutter/agent-plugins` and `mcp_flutter` are all free building blocks. FlutterCraft can compose them rather than rebuild them. Its value would come from:
  - curation
  - version-pinned rules matched to the project's Flutter SDK (via FVM)
  - verification loops that actually run `flutter analyze`, tests and builds, plus native-config checks
- Hosted builders (Dreamflow, Rocket, FlutterAIDev) own the beginner and vibe-coder segment but trade away code ownership and architecture control. That gap suits a local, open-source harness that can explain and enforce architecture to beginners.

### Gaps
- I found no reliable Reddit (r/FlutterDev) threads with direct quotes on Dreamflow or FlutterFlow AI output quality. The searches returned mostly SEO articles.
- FlutterFlow's own 2026 pricing and AI feature list were not verified from flutterflow.io.
- I found no "awesome-cursorrules Flutter" statistics or specific community Claude Code Flutter skill packs with traction numbers, beyond directory listings ([skills-hub.ai](https://skills-hub.ai/skills/flutter), [skillsdirectory](https://www.skillsdirectory.com/skills/loopyluci-flutter-dev)).
- The Google–FlutterFlow acquisition claim remains unverified (see above).

---

## Q2. General multi-agent harnesses and orchestrators: features, architecture, criticisms

### Takeaway
The category has consolidated around three things:
- **Isolation:** git worktrees, or containers as in Sculptor
- **Session control:** real PTYs or tmux wrapping existing CLIs
- **Review:** diff/PR UIs

Survivors are mostly free and open source. Several well-known entrants died or pivoted in 2026 (Terragon, Crystal, Vibe Kanban, Omnara OSS). Claude Code's native Agent Teams feature is still experimental.

### Cited Findings

**Comparative inventory**

| Tool | Form / platform | Agents | Isolation / architecture | License / price | Traction / status (date) |
|---|---|---|---|---|---|
| Munder Difflin | Desktop app (Pixi.js "office" UI), macOS/Win/Linux | 12+ CLIs: claude, agy, codex, grok, kimi, qwen, opencode, crush, pi, copilot, cursor, custom | node-pty per agent rendered with xterm.js; "hive" = local git repo of plain files (memory, mailboxes, blackboard, event log) with a single committer; optional per-agent worktrees; hook server + router; orchestrator "Michael" (your clone); approval gates; circuit breaker (steer → constrain → stop) | MIT (art assets separately licensed); Pro $150/yr (launch $100) adds Stapler dictation, meeting transcription, webhooks (GitHub/Linear/Telegram) | 8.1k stars, 1.1k forks, 95 open issues, v0.5.3 pre-release (28 Sep 2026) — [GitHub](https://github.com/chaitanyagiri/munder-difflin); [site](https://munderdiffl.in/) |
| Conductor | macOS app | Claude Code, Codex, Cursor | New git worktree per workspace; diff viewer + PR flow | Proprietary; free + paid (Teams plan, cloud option) | v0.87.5 — [conductor.build](https://www.conductor.build/); pricing tiers per [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/) (competitor-authored) |
| Claude Squad | Terminal TUI (needs tmux) | Claude Code, Codex, Gemini, Aider | tmux + git worktrees | AGPL-3.0, free | Active — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/); [Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/) |
| Sidecar (marcus/sidecar) | Go TUI; macOS/Linux/WSL | Claude Code, Codex, Gemini, Cursor, OpenCode, Pi | Workspaces + split panes with embedded agent shells; worktree management; cross-project sessions screen; git diff/stage; `td` task monitor; file browser; no telemetry | MIT, free | 1.1k stars, 82 forks, 3,147 commits, "ready for daily use" — [GitHub](https://github.com/marcus/sidecar) |
| Vibe Kanban (Bloop) | Web board via npx | Multi | Task card → worktree + branch; in-board diff review | Apache-2.0 | Bloop announced shutdown 10 Apr 2026 ([search summary citing dev.to/nimbalyst](https://dev.to/stravukarl/best-tools-for-managing-parallel-ai-coding-agents-in-2026-14l8)); "sunsetting / community maintenance" per [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/) |
| Crystal → Nimbalyst | Desktop, mac/Win/Linux | Claude Code, Codex | Worktrees, kanban, markdown/diagram editors | MIT; free + paid | Crystal deprecated Feb 2026, replaced by Nimbalyst — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/) |
| Emdash | Desktop, mac/Win/Linux | Multi-provider | Linear/Jira/GitHub issue integration, browser preview | Apache-2.0, free; YC-backed | [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/) |
| Sculptor (Imbue) | Desktop | Claude Code first, Codex added | Docker container per agent (not worktree), syncs back to local repo | MIT, free in beta | Active as of June 2026 — [search summary / agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools); [GitHub](https://github.com/imbue-ai/sculptor) |
| Terragon | Cloud background agents | Claude Code | — | Code open-sourced as an unmaintained snapshot | Shut down 9 Feb 2026, "insufficient traction" — [agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools) (secondary) |
| Omnara | "Control Claude Code from your phone" | Claude Code | — | OSS repo deprecated Nov 2025 | Pivoted to enterprise agent control plane — [agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools) (secondary) |
| Agent Orchestrator (AO) | — | Fleet of agents | Branches, reviews, CI failure tracking | Apache-2.0, free | [orchestrator.inc](https://orchestrator.inc/) |
| Claude Code Agent Teams | Built into Claude Code | Claude only | Lead + teammates (separate instances), shared task list with file locking, JSON mailboxes in `~/.claude/teams/.../inboxes/`, in-process or tmux/iTerm2 split panes, hooks (`TeammateIdle`, `TaskCreated`, `TaskCompleted`) | Included | Experimental, off by default (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) — [Claude Code docs](https://code.claude.com/docs/en/agent-teams) |

- **Claude Code Agent Teams limitations (official docs):**
  - no resume for in-process teammates
  - task status can lag
  - one team per session
  - no nested teams
  - two teammates editing the same file overwrite each other
  - split panes are not supported in VS Code terminal, Windows Terminal or Ghostty
  - "significantly more tokens" than a single session
  - the docs recommend 3–5 teammates

  — [Claude Code docs: agent teams](https://code.claude.com/docs/en/agent-teams)
- **Cloud agents, framed as architectural paradigms (secondary):**
  - Claude Code: synchronous terminal/IDE orchestrator with native parallel subagents
  - Codex: desktop app with a model router that prefers cloud task delegation
  - Google Jules: asynchronous task pool on cloud VMs that returns PRs; free tier of 15 tasks/day

  Criticisms:
  - Cursor's advertised 200K window yields "70–120K usable tokens"
  - "Since February 2026, Claude Code's defaults regressed and need /effort max"
  - "75% of AI coding agents broke working code during CI workflows" (single uncited study; treat with caution)

  — [digitalapplied Q2 2026 matrix](https://www.digitalapplied.com/blog/claude-code-vs-codex-vs-jules-q2-2026-matrix); [ssojet comparison](https://ssojet.com/blog/ai-coding-agents-compared) (secondary aggregators)
- **Zed Agent Client Protocol (ACP):**
  - JSON-RPC 2.0 over stdio between agents and editors
  - public registry co-launched with JetBrains on 28 Jan 2026
  - headline feature of Zed 1.0 (29 Apr 2026)
  - more than 40 registered agents by 20 Apr 2026 and more than 50 by late June 2026 (Claude Code, Gemini CLI, Codex, Copilot, Goose, and others)
  - native in Zed and JetBrains; community plugins for Neovim, Emacs and VS Code

  — [Zed ACP](https://zed.dev/acp); [Zed blog: ACP registry](https://zed.dev/blog/acp-registry); [danilchenko.dev](https://www.danilchenko.dev/posts/agent-client-protocol/). Sources conflict on the launch date ("released August 2025" vs "created June 2025"), per [Morph](https://www.morphllm.com/agent-client-protocol) and [groundy](https://groundy.com/articles/acp-registry-is-live-zed-and-jetbrains-just-did-for-ai-agents-what-lsp-did/).
- **Three architecture camps** are named in roundups: terminal session managers (Claude Squad), parallel-worktree desktop apps (Conductor, Crystal), and task boards (Vibe Kanban), plus "coordinated hives" (Munder Difflin). — [search summary of Munder/Nimbalyst roundups](https://nimbalyst.com/blog/best-multi-agent-coding-tools-2026/)

### Inferences
- **The worktree-per-agent + PTY + diff-review stack is now commodity.** FlutterCraft should not try to win on generic orchestration. It should reuse the pattern and differentiate on domain.
- **ACP is becoming the standard structured-output channel for agent CLIs.** Supporting it (alongside raw PTY) would give FlutterCraft structured tool-call and diff events without scraping terminal output. This is an architectural recommendation, not a finding.
- **Sidecar is the closest analog to FlutterCraft's current Textual TUI.** Both are TUIs with workspaces, git, file browser and embedded terminal. Sidecar is Go with MIT license and 1.1k stars, and is already multi-agent-aware. It is a direct UX benchmark.
- **The churn is high** (Terragon, Crystal, Vibe Kanban, Omnara OSS all died or pivoted within about 10 months). Standalone generic orchestrators have weak moats once the agent vendors ship native teams and cloud tasks.

### Gaps
- Conductor pricing tiers were not verified on conductor.build (the fetched page lacked prices).
- OpenHands and Cursor background-agent specifics were not fetched this round.
- Codex cloud task pricing was not verified.
- Claude Squad star count was not fetched.

---

## Q3. HN and Reddit discussion of Munder Difflin and similar tools: what users value vs. find gimmicky

### Takeaway
Munder Difflin got strong launch attention (312 points, 145 comments on HN; 8.1k GitHub stars). But HN commenters split between enjoying the concept and dismissing the Office-themed visual UI as "too cute". They wanted a utilitarian view and doubted whether autonomous agent "personalities" produce anything but dysfunction.

### Cited Findings
- **HN launch thread**, "Munder Difflin – Agent harness to run an office of your clones": 312 points and 145 comments, posted about 36 days before 28 Sep 2026, so roughly late August 2026. — [HN 49398152](https://news.ycombinator.com/item?id=49398152)
- The creator (Chaitanya) posted in the thread, claiming "20K+ users in a week" (self-reported, unverified), deterministic simulations that "do not consume tokens", and reduced token use via memory. — [HN 49399018](https://news.ycombinator.com/item?id=49399018); [HN 49398152](https://news.ycombinator.com/item?id=49398152)
- **What commenters valued:** the creative theming. User Aurornis said "the embrace of The Office as a theme... accurately represents the dysfunction of all... agent swarms". — [HN 49398152](https://news.ycombinator.com/item?id=49398152)
- **What they criticized:**
  - Unclear purpose. bot403: "was hard to tell from a quick read if this was a fun game with LLMs or a productivity tool".
  - UI as gimmick. joshstrange: "Trying to be too cute... I want a more utilitarian view".
  - Chaotic orchestration. Aurornis: "different personalities pursuing... little goals... competing with each other".
  - IP concerns. mcmcmc called the use of Office characters "lazy".
  - Skepticism that token savings justify the added complexity.

  — [HN 49398152](https://news.ycombinator.com/item?id=49398152) (thread paraphrased by fetch tool; quotes are partial)
- Munder Difflin's own marketing is aimed at "engineers who already pay for Claude Code or Codex and want parallel agents without a new API bill". — [munderdiffl.in](https://munderdiffl.in/)
- Munder Difflin publishes SEO comparison content ranking competitors ("The Best Tools to Run Multiple Claude Code Agents (2026)", updated 10 Sep 2026). That is useful but author-affiliated. — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/)

### Inferences
- **Users value:**
  - reuse of existing subscriptions (no new API bill)
  - real PTYs, meaning authentic CLI behavior
  - persistent memory
  - approval gates

  **Users are skeptical of:**
  - heavy visual metaphors
  - "autonomous clone" framing
  - unbounded autonomy

  For professional Flutter devs, FlutterCraft should lead with a utilitarian TUI (as it already does) and make any gamified view optional.
- Beginners may like playful visualization more than HN's professional audience does. That tension argues for a "mode" split (pro vs guided) rather than one UI.

### Gaps
- I did not find Reddit (r/ClaudeAI, r/FlutterDev) threads on Munder Difflin, and no HN comment-level data for Conductor, Claude Squad or Sidecar in this round.
- The HN thread summary came from an LLM fetch tool; exact comment wording and usernames should be spot-checked before quoting publicly.

---

## Q4. Is there a tool that combines Flutter specialization with multi-agent orchestration?

### Takeaway
Yes, but only small and early ones. **Vide** (Norbert515/vide_cli) is the closest direct competitor: an open-source TUI agent orchestrator with specialized agent roles (including a "Flutter Tester"), worktrees, and deep Flutter runtime integration. It is Claude-Code-only today and small (114 stars). Everything else is either Flutter-only single-agent tooling or generic orchestration.

### Cited Findings
- **Vide (vide.dev / GitHub Norbert515/vide_cli):** "The open source agent orchestrator. Instead of one AI conversation, Vide orchestrates a team of specialized agents that research, implement, review, and test your code."
  - Roles: Lead, Researcher, Implementer, Tester, **Flutter Tester**, Solution Architect, QA Breaker, Code Reviewer.
  - Flutter integration: hot reload, screenshots, Moondream vision AI to "see and tap your app", widget-tree inspection, runtime MCP.
  - Architecture: git worktrees, async agent communication, iterative review cycles, and a remote daemon (REST + WebSocket, Tailscale recommended).
  - TUI built on `nocterm`, a Dart terminal UI framework, claiming 60fps rendering.
  - Agents: Claude Code only (feature-complete via official SDK / CLI subscription); Codex CLI and Gemini CLI "under review" or on the roadmap.
  - A mobile Flutter remote-control app is planned.
  - Apache-2.0, free. 114 stars, 14 forks (28 Sep 2026). macOS, Linux, Windows.
  - — [vide.dev](https://vide.dev/); [GitHub vide_cli](https://github.com/Norbert515/vide_cli)
- **peter14l/flutter-agent-orchestrator:** MCP server plus skill, TypeScript, MIT.
  - Defines 24 tools across "agent" roles:
    - Prompt Architect (Clean Architecture decomposition), Dependency Researcher, UI/UX Specialist (M3)
    - Backend, Compiler Doctor, QA, Code Quality, Security
    - Accessibility Auditor (WCAG 2.1 AA), Native Platform Specialist (iOS/Android/Web config), CI/CD, Drift DB, Observability
    - hackathon/demo helpers
  - Only 1 star, 0 forks and 7 commits, so it is effectively a prototype. It is role-prompted tools inside one host agent, not process-level orchestration.
  - — [GitHub](https://github.com/peter14l/flutter-agent-orchestrator)
- **VGV AI plugin:** single-agent with one reviewer subagent and a "Green Gate" quality loop. Claude Code only. — [GitHub](https://github.com/VeryGoodOpenSource/very_good_ai_flutter_plugin)
- **mcp_flutter:** calls itself an "agentic harness" but is a feedback-loop MCP toolkit, not an orchestrator. — [GitHub](https://github.com/Arenukvern/mcp_flutter)
- **Flutter team blog**, "Flutter's multiplatform value for agentic development": argues a single Dart codebase cuts token overhead compared with translating features across platform-native languages. It positions Flutter as agent-friendly. — [Flutter blog](https://flutter.dev/blog/flutters-multiplatform-value-for-agentic-development)
- `agenix` (pub.dev) is a Dart package for building multi-agent AI features inside Flutter apps. It is not a coding harness, so it is not a competitor. — [pub.dev agenix](https://pub.dev/packages/agenix)

### Inferences
- **Vide is the one to watch.** It has the same thesis (Flutter-aware multi-agent orchestration in a TUI). Its gaps are also FlutterCraft's openings:
  - Claude-only (FlutterCraft targets Claude, Codex and Gemini)
  - no evidence of beginner onboarding, architecture templates, accessibility audits, or native-config (Android manifest, iOS Info.plist, signing, flavors) specialization
  - no FVM or SDK-version management
  - small community
- **White space nobody clearly covers as of Sept 2026:**
  1. A multi-vendor (Claude, Codex, Gemini/agy) Flutter harness.
  2. Automatic install and pinning of official `flutter/agent-plugins` + Dart MCP + VGV skills + `mcp_flutter`, matched to the project's Flutter SDK via FVM.
  3. Dedicated reviewer or verifier agents for accessibility (semantics), native config (permissions, bundle IDs, signing, min SDKs) and architecture conformance, gated by real `flutter analyze`, test and build runs.
  4. A beginner "guided mode" that stays local and code-owning (unlike Dreamflow or Rocket).
  5. Release pipeline hooks (Codemagic, Fastlane, store metadata).

  All of this is inference from the absence of evidence, not proof that nobody does it.

### Gaps
- No user reviews or HN/Reddit discussion of Vide were found; its real-world quality is unknown.
- Vide's release cadence and last-commit date were not captured.
- I could not confirm whether any commercial product (e.g., a FlutterFlow agent mode) runs multiple coordinated agents.

---

## Q5. Pricing and business models in this space

### Takeaway
There are three dominant models:
1. **Free, open-source harness with an optional Pro tier** for non-core extras (Munder Difflin).
2. **Free local app with paid team/cloud plans** (Conductor, Nimbalyst).
3. **Credit-metered hosted builders** for non-developers (Dreamflow at $0/$20/$90/month).

Orchestration itself is rarely what people pay for. They pay for extras (dictation, cloud, collaboration) or for generation credits. Free-only projects without a business model have a high death rate.

### Cited Findings
- **Munder Difflin:** the core is free and MIT. Pro costs $150/yr, adjusted for purchasing power, with a launch offer as low as $100. Pro adds Stapler dictation and transcription, an enhanced sidebar and inbound webhooks. Teams plans are also referenced. — [GitHub](https://github.com/chaitanyagiri/munder-difflin); [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/)
- **Conductor:** proprietary; "free + paid plans", with a Teams plan offering live collaboration and a cloud option. — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/) (competitor-authored; prices not verified)
- **Nimbalyst:** MIT, "free + paid". — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/)
- **Free open source, no paid tier seen:** Claude Squad (AGPL-3.0), Sidecar (MIT), Vide (Apache-2.0), Emdash (Apache-2.0, VC/YC-backed), Sculptor (MIT, free in beta), mcp_flutter (MIT), VGV plugin (MIT; VGV monetizes through consulting). — [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/); [Sidecar](https://github.com/marcus/sidecar); [Vide](https://github.com/Norbert515/vide_cli); [Sculptor via agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools)
- **Dreamflow:**

  | Tier | Price | Credits and extras |
  |---|---|---|
  | Free | $0 | 10 credits |
  | Hobby | $20/mo | 100 credits, code export |
  | Pro | $90/mo | 500 credits, Git |
  | Enterprise | custom | BYOM |

  Code export and Git are paywalled. — [dreamflow.app](https://dreamflow.app/)
- **Google Jules:** free tier of 15 tasks/day. — [digitalapplied](https://www.digitalapplied.com/blog/claude-code-vs-codex-vs-jules-q2-2026-matrix) (secondary)
- **Claude Code Agent Teams:** included with Claude Code, though it costs more tokens. — [Claude Code docs](https://code.claude.com/docs/en/agent-teams)
- **Failures and pivots:**
  - Terragon shut down (Feb 2026, insufficient traction)
  - Vibe Kanban's parent Bloop shut down (Apr 2026)
  - Crystal was deprecated (Feb 2026)
  - Omnara moved to enterprise

  — [agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools); [dev.to/stravukarl](https://dev.to/stravukarl/best-tools-for-managing-parallel-ai-coding-agents-in-2026-14l8); [Munder blog](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/)

### Inferences
- **BYO subscription is table stakes.** Users explicitly want to reuse their existing Claude or Codex plans. This matches FlutterCraft's wrapper design and means FlutterCraft should not resell tokens.
- **Plausible monetization paths for FlutterCraft**, following the observed patterns:
  - open-source core (it is AGPL-3.0 already, like Claude Squad)
  - a paid Pro tier for curated or updated Flutter rule packs synced to each Flutter release
  - store-release automation
  - team features
- Dreamflow's paywall on export and Git is a clear contrast point for marketing to beginners: "you own the code from minute one".

### Gaps
- Conductor, Nimbalyst and Emdash exact prices were not verified.
- Revenue and user numbers for any orchestrator are unavailable, apart from Munder Difflin's self-reported "20K+ users in a week" and Dreamflow's "2M+ builders" (likely a FlutterFlow-wide figure; unverified).
- FlutterFlow 2026 plan prices were not verified from the official site.
