<!-- covers:
packages/appstein_engine/lib/src/config/**
packages/appstein_engine/lib/src/text/**
packages/appstein_protocol/lib/src/config/**
-->

# `appstein.yaml`

## What the file is

`appstein.yaml` sits at a project's root and holds the project's Appstein settings: which packs it uses, verifier settings, where human docs go, and so on. The keys, and why each exists, are in [spec §7](../project/specs/2026-09-29-appstein-design.md#7-project-configuration-appsteinyaml). This page explains how the code loads and validates the file.

Two packages share the work:

- **The data** is `AppsteinConfig` in the protocol package, [`appstein_config.dart`](../../packages/appstein_protocol/lib/src/config/appstein_config.dart), with one class per section (`PacksConfig`, `DeltaConfig`, `VerifyConfig`, `DocsConfig`, `PackagesConfig`, `IntegrationsConfig`). The defaults live in their constructors, and `toJson` uses the same key names as the YAML file.
- **The loading and validation** is in the engine, [`config_loader.dart`](../../packages/appstein_engine/lib/src/config/config_loader.dart).

## Loading

- **`loadConfig(projectRoot)`** reads `appstein.yaml` from the project folder. It returns **null when the file doesn't exist**: that isn't an error, it means the project isn't set up with Appstein yet. A file that exists but can't be read (not UTF-8, or locked) is a `ConfigException` without a line, whose message gives the reason, in the OS's words when it gave any ("Access is denied."; see [running-tools](running-tools.md#fileerrorreason)).
- **`parseConfig(content)`** parses and validates the text. **Every key has a default, so an empty file is valid**, and so is a file with only some sections. A key or section with no value (`packs:` and nothing under it) also takes its default.

The parser reads each section with small helpers that check the type of each value, so every error points at the value that is wrong.

## The keys

Built from the parser and the `AppsteinConfig` classes:

| Key | Type | Default | Allowed values |
|---|---|---|---|
| `appstein` | whole number | `1` | Only `1`, the `supportedConfigFormat`. Another number is "Config format N is not supported" |
| `packs.stack` | text | `official_mvvm` | One of `knownStacks`: `official_mvvm` |
| `packs.platforms` | list of text | `[android, ios]` | Each one of `knownPlatforms`: `android`, `ios`. At least one, no duplicates |
| `delta.baseline` | quoted text | `"3.16"` | A Flutter major.minor version only, like `"3.16"`; `"3.16.0"` is an error. It must be quoted: unquoted, YAML reads `3.20` as the number 3.2, so a number is an error |
| `verify.fast_timeout_seconds` | whole number | `20` | 1 or more |
| `verify.build_on_full` | `true` or `false` | `true` | |
| `verify.severity` | map | empty | Keys are check IDs: two or more lowercase words joined by dots (`ui.no_hardcoded_colors`). Values are `error`, `warning` or `info` |
| `docs.enabled` | `true` or `false` | `true` | |
| `docs.path` | text | docs/app (in the project) | A folder inside the project, relative to its root. Absolute paths, `.` and paths that climb out with `..` are errors. So is a path whose first folder is `.appstein`, `.git`, `.dart_tool`, `build`, `lib` or `test`: pages there would be mixed with files other tools own or delete. The name is compared as Windows and macOS see it, so `Lib` and `build.` are refused too. Backslashes become `/` |
| `packages.stale_after_months` | whole number | `12` | 1 or more |
| `packages.allow` | list of text | `[]` | Package names (lowercase letters, digits and `_`), no duplicates |
| `packages.deny` | list of text | `[]` | As `packages.allow` |
| `integrations.agents` | list of text | `[claude, codex]` | Each one of `knownAgents`: `claude`, `codex`. No duplicates |
| `integrations.graphify_export` | `true` or `false` | `false` | |
| `integrations.developer_knowledge_mcp` | `true` or `false` | `false` | |
| `suppressions` | list of maps | `[]` | Each entry has `id`, `path` and `reason`; see below |

**`suppressions`** is the list of findings the project accepts (spec §9.7; how they are applied is in [verify](verify.md#suppressions)). Each entry becomes a `SuppressionEntry` with the line it is on, so a finding about the entry can point at it:

```yaml
suppressions:
  - id: verify.test_required
    path: lib/ui/profile
    reason: covered by the integration tests
```

- `id` is a check ID, in the same form as a `verify.severity` key.
- `path` is a file, a folder or a glob, from the project folder, with `/`. A backslash, an absolute path, `..` and a glob that isn't valid are errors.
- `reason` may be missing or blank as far as the loader is concerned: it then loads as no reason, and `appstein verify` reports the entry as the error `suppression.no_reason`. A config error would stop every command; a finding names the line and still lets `verify` run.
- Any other key in an entry is an error, with the "did you mean" hint.

The top level and each section must be a map. The lists of known values (`knownStacks`, `knownPlatforms`, `knownAgents`) are constants in `config_loader.dart`, and they grow as later slices add packs and agents.

## Errors

**`ConfigException`** carries a message written for the person editing the file, plus the file, line and column (1-based) when they are known. Its text puts the position first, so an editor or terminal can jump to it:

```text
C:\my app\appstein.yaml:3:10: packs.stack must be one of: official_mvvm.
```

That is the error for `stack: foo` on line 3, indented by two spaces: the position is the start of the value `foo`.

Every validation error takes its position from the YAML node that is wrong, and a YAML syntax error takes it from the parser's error span.

**Unknown keys are errors, with a "did you mean" hint.** A typo such as `platfroms` would otherwise be ignored silently, and the default used without anyone noticing. The message names the key, suggests the closest allowed key, and lists all of them:

```text
Unknown key "platfroms" in packs. Did you mean "platforms"? Allowed keys: stack, platforms.
```

The hint comes from [`edit_distance.dart`](../../packages/appstein_engine/lib/src/text/edit_distance.dart), in the engine's `text/` folder:

- `editDistance` is the Levenshtein distance: the fewest one-character insertions, deletions or substitutions that turn one string into the other.
- `closestMatch` returns the allowed key with the smallest distance, if it is at most 2 edits away; on a tie, the one listed first. Further away, there is no hint, because a far-off guess would mislead more than help.

**How it becomes exit code 3.** `runAppstein` catches a `ConfigException`, prints `Invalid appstein.yaml: ` and the error to stderr, and returns exit code 3 (see [cli](cli.md)). `doctor` never lets it get that far: its project check turns an invalid file into an error result, with exit code 1 ([doctor](doctor.md#finding-the-project)).

## Byte order marks

Windows PowerShell 5.1 writes UTF-8 files with a byte order mark (BOM), the invisible character U+FEFF, at the start. `parseConfig` strips a leading BOM before parsing, so such a file reads exactly like one saved without it. Appstein's JSON readers do the same, because `jsonDecode` rejects a BOM: the FVM pin, Flutter's settings file and Flutter's version file.

**The code writes the BOM as an escape, never as the raw character:** a backslash, then `uFEFF`, inside the string. The raw character is invisible in an editor, and a tool that strips it would silently change what the code compares against. CI's `analyze` job fails if any Dart file contains the raw character; see [ci](ci.md#analyze).

## Where config is used today

`loadConfig` has these callers:

- **`appstein verify`** and the MCP server's `verify` tool, which read **`verify.severity`** and **`suppressions`** ([verify](verify.md)), and **`docs`** for the `docs.stale` check.
- **`appstein docs`**, which reads **`docs.enabled`** and **`docs.path`** ([human-docs](human-docs.md)), and **`appstein mcp`**, which builds its sync from the file on every call ([mcp-server](mcp-server.md)).
- **`ProjectCheck` in `appstein doctor`**, which reports whether the file is valid and shows the stack and platforms ([doctor](doctor.md#finding-the-project)).
- **`appstein sync`**, which reads **`packs.stack`** to choose the stack pack and **`delta.baseline`** to choose how far back the version delta's curated notes reach ([version-delta](version-delta.md)). `packsFor` in the CLI maps `official_mvvm` to `OfficialMvvmPack`, and the pack's layer rules, features and routes shape the project map (see [cli](cli.md#appstein-sync) and [project-map](project-map.md#packs-and-the-core)). A project with no `appstein.yaml` gets the defaults, so `official_mvvm`. A broken file stops `sync` with exit code 3 before anything is written. It also reads **`packs.platforms`**: `packsFor` gives each listed platform its pack (`android` gives `AndroidPack`, `ios` gives `IosPack`), and those packs write `native.json` ([native-config](native-config.md)).

The other keys (`verify.fast_timeout_seconds`, `verify.build_on_full`, `packages.*`, `integrations.graphify_export`, `integrations.developer_knowledge_mcp`) are read by no command yet. The slices that use them are planned in the [spec](../project/specs/2026-09-29-appstein-design.md#53-commands).
