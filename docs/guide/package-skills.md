<!-- covers:
packages/appstein_engine/lib/src/skills/package_skills.dart
-->

# Package skills

Some packages ship agent skills of their own: folders under `skills/` in the package, each with a `SKILL.md`. Google's [package:skills](https://pub.dev/packages/skills) copies them into an agent's skill folder. Nothing re-runs it when the dependencies change (dart-lang/ai#585), so an agent can keep the skills of a package version the project no longer uses. `appstein sync` runs it whenever the dependencies change, so the agent has the skills for the **installed** version of each package (spec §6.6).

Everything lives in one file, [`package_skills.dart`](../../packages/appstein_engine/lib/src/skills/package_skills.dart). `KnowledgeSync` calls `PackageSkills.refresh` after it has written the knowledge (see [knowledge-store](knowledge-store.md)).

## When it runs

A run is due when the **record** says the inputs changed. The record is [`PackageSkillsRecord`](../../packages/appstein_engine/lib/src/skills/package_skills.dart), stored in `.dart_tool/appstein/package_skills.json` (`packageSkillsRecordPath`), next to the analyzer cache. It is local to each clone and never committed. It holds:

- the SHA-256 of `pubspec.yaml` and of `pubspec.lock`, taken from the map's inputs after any `flutter pub get` the sync ran (see [incremental-sync](incremental-sync.md#the-maps-inputs));
- the agents it ran for;
- the package:skills version (`packageSkillsVersion`);
- whether the run worked.

`sameInputs` compares everything but the last. So a run is due when there is no record (a fresh clone, or the record was deleted or damaged), or when the dependencies, the set-up agents or the pinned version changed.

**Retrying a failure.** A record that says the run failed is due again only on a full sync: `KnowledgeSync.run` passes `retryFailure: true`, and `detect` passes `false`. Offline, `dart run skills@1.0.3` fails only after about 41 s, because pub retries pub.dev. Retrying on every `sync --detect` would add that to every edit. The SessionStart hook runs a full sync, so a failure is retried once per session, and at once when the dependencies change again.

## For which agents

[`setUpAgents`](../../packages/appstein_engine/lib/src/skills/package_skills.dart) keeps the agents of `integrations.agents` (from `appstein.yaml`, see [config](config.md)) that are already set up in the project:

| Agent | Set up when | Skills go to |
|---|---|---|
| `claude` | `.claude/` is a folder | `.claude/skills/` |
| `codex` | `.agents/` is a folder or `AGENTS.md` is a file | `.agents/skills/` |

`sync` never creates an agent's folder. With no agent set up, nothing runs, and the record says so (with no agents), so the "skipped" line appears once per change, not on every sync. Setting an agent up later changes the agent list, which makes a run due.

## The command

```text
<flutter>/bin/dart run skills@1.0.3 -C <project> get --all --agent claude --agent codex
```

- **The SDK's own `dart`** ([`dartCommand`](../../packages/appstein_engine/lib/src/skills/package_skills.dart): `bin/dart`, or `bin\dart.bat` on Windows), never the `dart` on PATH, which may be an older SDK. It is started in the project folder too.
- **The version is pinned exactly** and moves with Appstein releases. `dart run pkg@version` needs Dart 3.12, which every supported Flutter (3.44 and later) has.
- **`--all`**, because without a terminal `get` only lists what it would install. `--all` also recopies every skill package:skills manages, so local edits to those skills are lost, and it deletes the skills of packages that were removed.
- **The time limit** is 120 s (`packageSkillsTimeout`); the run is then stopped and counts as failed.
- **The packages first.** When package:skills finds no `.dart_tool/package_config.json`, it runs `dart pub get` itself, with the `dart` on PATH. So `refresh` doesn't run when the sync couldn't fetch the packages (`packagesReady`); that is a failure with the reason "the packages could not be fetched".

## Judging a run

package:skills exits 0 on most errors. A real run of 1.0.3 showed it:

- an unknown agent prints `"nosuch" is not an allowed value for option "--agent".` and the usage text, and exits 0;
- a failed internal `pub get` prints `Failed to run pub get.` and the usage text, and exits 0;
- pub.dev unreachable exits 255.

So [`packageSkillsFailure`](../../packages/appstein_engine/lib/src/skills/package_skills.dart) counts a run as working only when it exited 0 **and** printed `Installed N skill(s) for <agent> at …` for every agent it was given. It prints that line even when N is 0 (no package ships skills), and it prints Codex as `generic`, the agent `--agent codex` is an alias of. Otherwise the reason says what happened and quotes the first 10 lines of output.

## Two syncs at once

The SessionStart hook and an after-edit hook can both sync at the same moment. `refresh` takes the operating-system lock on `.dart_tool/appstein/` (`KnowledgeLock`, the same kind as the knowledge store's, on another folder) with **no wait**. A sync that finds it taken returns null at once: the other sync is running package:skills. Inside the lock it reads the record again, because the other sync may have finished a run between the first check and the lock. The lock is never the knowledge lock, so a run of several seconds never holds up another sync's knowledge write.

## What it writes

Besides its record, package:skills itself writes:

- the agent skill folders above, and `.config/dart_skills/skills_config.json`, its list of what it installed; both are committed (spec §6.2's git table);
- `.dart_tool/skills/`, its cache;
- `dart_skills/global_config.json` in the user's application-data folder (`%APPDATA%` on Windows, `~/Library/Application Support` on macOS, `$XDG_CONFIG_HOME` or `~/.config` on Linux), rewritten on every run. It is that tool's own bookkeeping, not agent config or credentials, and it offers no way to skip it (spec §6.6).

It also sends the package names and versions to osv.dev to check for advisories.

## What sync prints

At most one line, from `formatPackageSkills` (see [cli](cli.md#appstein-sync)):

```text
Package skills: refreshed for claude, codex.
Package skills: skipped, because no agent in integrations.agents is set up in this project (claude needs .claude/; codex needs .agents/ or AGENTS.md).
warning: package skills could not be refreshed (the packages could not be fetched); the next appstein sync tries again.
```

When nothing was due, it prints nothing. A record that couldn't be saved adds a warning that the next sync runs package:skills again. The time spent is the `package skills` step of `--timings`; spec §15 leaves a run out of sync's time targets, since it happens only on dependency changes and depends on the network.

## Tests

- `packages/appstein_engine/test/skills/package_skills_test.dart`: which agents are set up, the record (round trip, damaged or foreign files, `sameInputs`), judging each real output, and `refresh`: due or not, the retry rule, no agents, packages not fetched, a held lock, a record that can't be saved.
- `packages/appstein_engine/test/knowledge/knowledge_sync_package_skills_test.dart`: the wiring into `run` and both branches of `detect`.
- `packages/appstein_engine/test/integration/package_skills_real_test.dart`: the real `skills@1.0.3` installs a path dependency's skill for both agents, in a folder with a space and an umlaut. It needs pub.dev.
- `packages/appstein_cli/test/sync_command_test.dart`: the `package skills` group (the lines) and two real syncs that pass `integrations.agents`.
