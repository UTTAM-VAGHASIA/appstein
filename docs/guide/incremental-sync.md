<!-- covers:
packages/appstein_engine/lib/src/map/analyzer_cache.dart
packages/appstein_engine/lib/src/map/map_inputs.dart
packages/appstein_engine/lib/src/knowledge/freshness.dart
packages/appstein_engine/lib/src/knowledge/sync_timings.dart
-->

# Incremental sync

An agent's hook runs `appstein sync --detect` after every edit (spec §5.4). It must cost almost nothing when the edit changed nothing the knowledge reads, and stay under 2 s when it did (§15). This page explains how.

## The idea

`--detect` never patches the knowledge. It does one of two things:

- it finds that nothing changed, and stops;
- it finds that something changed, and runs the **same full sync** as `appstein sync`.

So what `--detect` writes can never differ from what a full sync writes. There is no second way to build a file, and so no second way to get one wrong.

Either way, it then refreshes package skills when they are due, as a full sync does, except that it doesn't retry a run that failed with the same inputs (see [package-skills](package-skills.md#when-it-runs)).

The speed comes from the **analyzer cache**: the Dart analyzer keeps what it worked out about each library, so a rebuild only analyzes what changed. Everything else in a sync is cheap.

Before this slice every sync took about 9 s on a 200-file app, and a full sync of 1,000 files took about 34 s (most of it a cubic loop in `readFeatures`, see [project-map](project-map.md#features)). Measured with [`tool/measure_sync.dart`](../../tool/measure_sync.dart) on the Windows development machine, each sync a new process:

| Measurement | 200 files | 1,000 files (info) |
|---|---|---|
| First sync, with `flutter pub get` | 10,692 ms | 11,370 ms |
| Full sync, no analyzer cache (target under 30 s) | 6,892 ms | 7,618 ms |
| `sync --detect`, nothing changed (target under 2 s) | 77 ms | 165 ms |
| `sync --detect` after editing a view model (target under 2 s) | 1,102 ms | 2,202 ms |
| `sync --detect` after editing the router | 1,167 ms | 2,309 ms |

## How `--detect` decides

[`KnowledgeSync.freshness`](../../packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart) answers "does `.appstein/` hold what a sync would write now?" without analyzing or writing anything. [`KnowledgeSync.detect`](../../packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart) calls it and rebuilds when the answer is no.

It runs the cheap steps of a sync for real, in `_prepare`:

1. the platform layer (about 8 ms);
2. `checkPackages`, which says whether `flutter pub get` is needed;
3. the map's inputs, `readMapInputs` (20 to 110 ms, see below);
4. native config (about 5 ms);
5. `readIndexSources`, which reads what INDEX.md summarizes.

Then it computes **every output's input hash** and compares it with the one in `state.json`. It uses the same functions a sync uses: `_deltaHash` and `_indexHash` were pulled out of the building code for this. "Current" therefore can't use a different idea of what the inputs are than a sync does. The map's files all share the map's hash. `map/native.json` and the platform files bring their own.

`freshness` returns a [`Freshness`](../../packages/appstein_engine/lib/src/knowledge/freshness.dart): `current` (true when there are no `reasons`), the `reasons`, the `changed` input names and the `state.json` it compared with. A reason is written to follow "because". The ones that don't name a file:

| Reason | When |
|---|---|
| `no sync has run here yet` | there is no `state.json` |
| `state.json is damaged or from an older Appstein` | it can't be parsed, or lacks the keys this version needs |
| `state.json could not be read (…)` | the file exists but can't be read |
| `the last sync was made by Appstein X` | another Appstein version wrote it |
| `state.json is in format N` | its format version differs from this Appstein's |
| `` the packages need `flutter pub get`: … `` | `checkPackages` says they are stale |
| `the last sync could not build the project map` | `state.json` has no `map/symbols.json` |
| `<file> is out of date` | a file's input hash differs from `state.json`'s (or the file is new, or no longer expected) |
| `<file> was changed by hand` | the file's bytes differ from the hash in `written` |
| `<file> is missing` | a file in `written` is not on disk |

A reason means a rebuild. A hand-edited or deleted file, a damaged `state.json` and a sync that was killed before it wrote `state.json` all end here: `--detect` never says "current" for knowledge that disagrees with `state.json`.

A rebuild rebuilds everything, `map/native.json` and `INDEX.md` too. Both cost under 15 ms and the store already skips writing a file whose bytes would be the same, so a separate "only my own inputs changed" path would add code and gain nothing you could measure.

## The map's inputs

[`readMapInputs`](../../packages/appstein_engine/lib/src/map/map_inputs.dart) reads everything the map is built from, before any analysis, and returns [`MapInputs`](../../packages/appstein_engine/lib/src/map/map_inputs.dart): `sources` (a SHA-256 for each input) and the shared `inputHash`. The input names are:

| Name | File |
|---|---|
| `project:<path>` | each `.dart` file under `lib/`, `test/` and `testing/` |
| `pubspec.yaml` | the project's |
| `pubspec.lock` | the workspace root's |
| `analysis_options.yaml` | the project's (its `exclude:` changes which files the map covers) |
| `local-package:<name>/<path>` | a local package's `pubspec.yaml`, and each `.dart` or `.yaml` file under its `lib/` |

A file that can't be read has no hash (`null`, written `missing` in `state.json`).

**The folders are walked as the analyzer walks them.** The inputs must cover exactly the files the map is built from, so `_filesUnder` copies the analyzer's walk (analyzer 14.4.0, `ContextRootImpl._includedFilesInFolder`):

- **Links are followed.** A link to a folder, or a Windows junction, is walked into, and a file behind it is named by its path through the link, as the analyzer names it: `project:lib/linked/s.dart`. An edit behind the link therefore changes the hash.
- **Loops end.** A folder whose resolved path is one the walk is already inside is skipped. Like the analyzer, the walk tracks only the folders on its current path, not every folder it has seen, so two links to one folder are both inputs (removing one changes the map, so it must change the hash). A link `lib/loop` to `lib` is walked once, as `lib/loop/…`, and stops at `lib/loop/loop`.
- **Only the unlistable folder is lost.** A folder that can't be listed, or whose link can't be resolved, is one input named after that folder alone, with a trailing `/` and no hash: `project:lib/locked/`, `local-package:<name>/lib/locked/`, or `project:lib/` when `lib/` itself can't be. Its siblings are still walked and hashed. The analyzer skips that folder too, so the map and the hash agree; when the folder becomes readable, its key disappears and its files appear, so the change is seen.

**Names, not paths.** The hash covers the names above, never an absolute path. A project folder that moves keeps its hashes.

**Local packages.** A path dependency, or a sibling package of a pub workspace, can change without `pubspec.lock` changing, so before this slice an edit there left the map stale. [`localPackageRoots`](../../packages/appstein_engine/lib/src/map/map_inputs.dart) finds them in the workspace's `.dart_tool/package_config.json`: every package that is in neither the Flutter SDK nor a pub cache folder, other than the project itself. Packages from pub.dev or git are pinned by `pubspec.lock`, and the SDK's by the Flutter version, so they need no hashing. The `.yaml` files under `lib/` are included because that is where `fix_data` for the version delta lives (see [version-delta](version-delta.md)). A missing or damaged package config means no local packages.

[`pubCacheFolders`](../../packages/appstein_engine/lib/src/map/map_inputs.dart) says where pub keeps downloaded packages: `PUB_CACHE` when set, else on Windows `%LOCALAPPDATA%\Pub\Cache` and `%APPDATA%\Pub\Cache`, else `~/.pub-cache`. A cache folder this list misses costs only time: its packages are hashed as local ones.

**Read before the analysis.** `MapSync` calls `readMapInputs` *before* it analyzes, not after. A file edited while the sync analyzes then leaves the **old** hash behind, because the hash describes what was there when the sync started. The next `sync --detect` sees a different hash and rebuilds. Reading after the analysis would record the new hash for a map built from the old text, and the edit would never be picked up. The test "a file edited while the sync analyzes is rebuilt by the next detect" pins this.

## `state.json`

`state.json` keeps format version 1 but has three new keys (`sources`, `written`, `changed`) beside `files`, all required when it is read:

| Key | Holds |
|---|---|
| `files` | each generated file's input hash (as before) |
| `sources` | the hash of each map input, by input name (`missing` for a file that couldn't be read) |
| `written` | the SHA-256 of each generated file's bytes, to catch a hand edit |
| `changed` | the input names whose hash differs from the previous `state.json`, sorted; files added and removed included |

`changed` is for the checks that come later: `verify --fast` (slice 1d) and the package skills (slice 1b.8) read it to look only at what changed. With no earlier `state.json`, `changed` lists every input, but the *report* (`SyncReport.changed`) is empty then, so a first sync doesn't print 200 "changed" files.

**Each change is reported once.** The first `--detect` that finds nothing changed empties `changed`. It does that inside the store's lock, and only if `state.json` is still exactly the one it checked (it compares the canonical JSON). If another sync wrote it in between, it leaves it alone. If the lock stays busy past the lock timeout, it skips emptying the list and still reports "current": nothing is stale, so a hook mustn't fail, and the writer holding the lock is writing a new `state.json` anyway. Every later `--detect` writes no byte.

**Older `state.json` files.** One written before 1b.7 lacks `sources`, `written` and `changed`, so it fails to read and `--detect` says "state.json is damaged or from an older Appstein" and rebuilds. That costs one rebuild. Raising the format version instead would have rewritten every generated file once, for no gain: nobody has 1b.6 state files.

## The analyzer cache

**Where it lives.** `.dart_tool/appstein/analyzer_cache.bin` ([`analyzerCachePath`](../../packages/appstein_engine/lib/src/map/analyzer_cache.dart)). `.dart_tool/` is where Dart tools keep their caches. Flutter's template git-ignores it and `flutter clean` deletes it.

**The owner's decision.** The analyzer's cache type (`ByteStore`) and the collection that accepts one (`AnalysisContextCollectionImpl`) are in its `src/` folder, with no public way to use them. The owner chose to use them. The rules that keep that safe:

- every use is in `analyzer_cache.dart`, under one `ignore_for_file: implementation_imports` with the reason; no other file may import `package:analyzer/src/…`;
- the engine's `pubspec.yaml` pins `analyzer` to exactly `14.4.0` (the lints package keeps `^14.4.0`: in a user's project the lint plugin is resolved apart from Appstein's binary);
- `analyzerVersion` in the file names the same version, and a test checks that the two agree.

**To upgrade the analyzer:**

1. change the pin in `packages/appstein_engine/pubspec.yaml` and `analyzerVersion` in `analyzer_cache.dart`;
2. run the canary test, "the analyzer stores its work in the cache and reads it back" in `analyzer_cache_test.dart`: it fails if the analyzer stops using the cache;
3. check that `AnalysisContextCollectionImpl` still takes a `byteStore` parameter and that `ByteStore` still has `get`, `putGet` and `release`.

An upgrade also changes `analyzerVersion`, so every existing cache file is read as damaged once and replaced.

**The file format.** [`encodeAnalyzerCache`](../../packages/appstein_engine/lib/src/map/analyzer_cache.dart) writes, with big-endian numbers:

```text
APPSTEIN ANALYZER CACHE\n
format            4 bytes (1)
analyzer version  2 bytes of length, then ASCII ("14.4.0")
entries, sorted by key:
  key             2 bytes of length, then ASCII
  value           4 bytes of length, then the bytes
```

Keys are sorted, so the same entries always give the same bytes. A save keeps **only the entries the run used** (read or added), so the file doesn't grow with entries nothing needs. `changed` on [`AnalyzerCache`](../../packages/appstein_engine/lib/src/map/analyzer_cache.dart) is false when the run added nothing and used all it loaded, and then nothing is saved.

**The probe's numbers.** At 200 files the cache is about 57 MB. Loading takes 12 to 22 ms and saving 60 to 77 ms.

**Why one file.** The analyzer's own `FileByteStore` keeps one small file per entry (2,394 files for the probe app). Reading them the first time took 13.5 s on Windows. Its `flush()` also doesn't work there (dart-lang/sdk#64190). One file, read once and replaced in one step (`replaceFileBytes`, the way every generated file is), avoids both.

**When it fails.** The cache never fails a sync and never changes the knowledge. Each case costs at most one slow sync and one line in the report:

| What happens | What the sync does | The report says |
|---|---|---|
| no cache file | analyzes from nothing, then saves | nothing |
| wrong header, another format or analyzer version, cut short, or unreadable | opens as an empty cache, then replaces the file | `The analyzer cache could not be used (<why>), so this sync analyzed without it.` |
| the header is fine but entries are garbage | the analysis fails; it runs once more with an empty cache, which replaces the bad one | `The analyzer failed while reading its cache (<error>), so the analysis ran again without it and the cache was replaced.` (without "and the cache was replaced" when the save then failed) |
| the cache can't be saved (a read-only folder, `.dart_tool/appstein` is a file, or any other error while saving) | the knowledge is already written; the sync succeeds | `warning: the analyzer cache could not be saved (<why>); the next sync will be slower.` |
| the map was skipped | leaves the cache file alone | nothing |

**Why `catchAnalyzerErrors` exists.** The probe found that a cache with garbage entries made the analyzer throw inside **its own scheduler**, where no `await` of ours can catch it. The process died with exit 255, and every later sync would have done the same until someone deleted the file by hand. [`catchAnalyzerErrors`](../../packages/appstein_engine/lib/src/map/analyzer_cache.dart) runs the analysis inside `runZonedGuarded`, so that error becomes the analysis's own error. `MapSync.build` then retries once with `AnalyzerCache.empty`. Without a cache, or when the retry fails too, the error is thrown and the CLI turns it into exit 3 with a crash report. The abandoned first analysis isn't disposed, because its futures never complete; the process still exits normally.

## Measuring

[`tool/measure_sync.dart`](../../tool/measure_sync.dart) times each sync the way a hook runs it:

- it compiles the real `appstein` executable first, and runs every sync as a **new process**. CI's JIT `dart run` would distort the numbers;
- it sets `FLUTTER_ROOT` to the Flutter SDK whose Dart runs the tool;
- it makes the apps in a new folder inside `--work` (the system temp folder by default). CI passes its own temporary folder, on the disk that holds the checkout: on Windows runners the system temp folder is on a slow remote disk, which made the cache's write cost up to 3.8 s (see [ci](ci.md#measure));
- the **full sync row is cold**: it deletes `.appstein/` and the cache folder first, so it is the 30 s worst case;
- before the "nothing changed" row it runs `--detect` once to empty the change list, then times the next ones;
- each **detect row is the median of three runs** (owner decision, after the first public CI runs), and the table shows the three times beside it. The edit rows make three different edits, each followed by a detect. A CI machine's speed varies from run to run, so one slow run must not fail the target, while a real slowdown still moves the median. The full sync stays one run: it is cold, and far under its 30 s;
- the 1,000-file rows' **times are information only** (owner decision): they are printed and never held to a target. The 200-file rows' times are held to spec §15 (full sync under 30 s, each detect under 2 s).

At both sizes the tool still fails (exit 1) when a run is broken: a sync that fails, a run that isn't a real sync (a skipped map, unread native config), or an edit that isn't reported as changed. So a fast wrong answer can't pass.

### Where the time goes

A total alone can't say why a run is slow, and the slow run may be on a CI machine nobody can log in to. So every sync times its own steps, and the tool prints them as a second table, one column per full sync and edit.

- [`SyncTimings`](../../packages/appstein_engine/lib/src/knowledge/sync_timings.dart) adds up each step's time, in the order the steps started. `KnowledgeSync` times its steps (the platform layer, the packages check, the map's inputs, the freshness check, the cache load and save, the knowledge write, package skills), and `MapSync.build` times its own (`flutter pub get`, the analysis, the extractors, the delta's facts, closing the analysis). The result is `SyncReport.timings`.
- A name that starts with two spaces is **part of the step before it**: the temporary-file writes and renames inside the knowledge write and the cache save. They come from `replaceFile`'s `onTimed` (the store passes its `onReplace`), which also counts the renames Windows refused and that were retried. Only the other steps add up to the run.
- The CLI prints the steps with the hidden `--timings` flag (see [cli](cli.md#appstein-sync)). The tool adds a row for the time outside every step, which is starting and ending the process.

Timing costs a few stopwatch reads, so every sync does it, and the numbers are always there when a target is missed.

## Tests

- `packages/appstein_engine/test/map/analyzer_cache_test.dart`: the file format (round trip, only used entries kept, sorted keys, every kind of damage), the path, the canary with the real analyzer, the version pin, and `catchAnalyzerErrors`.
- `packages/appstein_engine/test/map/map_inputs_test.dart`: the input names, local packages, pub cache and SDK packages skipped, damaged package config, `pubCacheFolders`, that a moved project keeps its hash, and the walk: a linked folder (a junction on Windows), two links to one folder, a link loop, and (POSIX only) an unreadable folder beside hashed siblings.
- `packages/appstein_engine/test/knowledge/knowledge_sync_cache_test.dart`: the cache is created and read, the knowledge is the same with a warm cache as with none, a damaged cache, garbage entries (the guard and the retry), a cache that can't be saved, and a skipped map.
- `packages/appstein_engine/test/knowledge/knowledge_sync_detect_test.dart`: the freshness matrix. Nothing changed (and the change list emptied once, or left for later when the lock is busy), each kind of change, hand edits and a damaged or older `state.json`, a file edited while the sync analyzes, a skipped map tried again, an edit behind a linked folder, "current" reached with the Android and iOS packs and after a decision-file rebuild, native and other packs.
- `packages/appstein_engine/test/knowledge/sync_timings_test.dart`: steps add up and keep their order, a step comes before its parts, and a step that throws is still timed. `knowledge_sync_detect_test.dart`'s "timings" group names the steps of a rebuild and of a "current" detect, and `knowledge_store_test.dart` checks `onTimed`, its retry count (Windows) and `onReplace`.
- `packages/appstein_cli/test/sync_command_test.dart`: `--detect` and its report lines, that `--changed` is not an option, and `--timings` (its lines come after the report, and it is left out of the help).

See [testing](testing.md) for how these tests are built, and [knowledge-store](knowledge-store.md) for how the files are written.
