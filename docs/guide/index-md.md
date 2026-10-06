<!-- covers:
packages/appstein_engine/lib/src/index/**
-->

# INDEX.md

`appstein sync` writes `.appstein/INDEX.md`: the one page an agent always has in view (spec §4 principle 5, §6.3). Everything else in `.appstein/` is read on demand. INDEX.md says what the project is and where to look next. It is at most 1,500 tokens, and the rest of this page explains how that is kept.

It names MCP tools, but **only the ones this Appstein offers** (spec §6.3). An agent that is told to call a tool that doesn't exist wastes a turn finding that out. `sync` passes the server's own list, [`mcpToolNames`](../../packages/appstein_engine/lib/src/mcp/tool_names.dart), as `IndexInputs.tools`. Of the tools INDEX.md can name (`indexTools`), four aren't served yet: `verify` and `package_check` (slice 1d), `decisions` and `memory_read` (slice 1c.2). Until each one joins the list:

- the rule "Run `verify()` before you say a task is done" is left out;
- the dependency rule says "a well-maintained package" where it will say "a package that passes `package_check()`";
- the pointers for hidden decisions and current work name the file (`decisions/`, `memory/current.md`).

Adding a name to `mcpToolNames` is all it takes for INDEX.md to name the tool.

## What it holds

| Section | Holds | From |
|---|---|---|
| Project | The Flutter, Dart and language versions; the stack pack; the platform folders; the Android and iOS ids | `sdk.json`'s facts, the pack list, the project's platform folders, `map/native.json` |
| Rules | Up to four fixed rules: ask the MCP tools before searching, run `verify()` before saying done (once that tool exists), never upgrade native toolchain versions yourself, and how to choose dependencies | fixed text in the code |
| Features | At most 15 rows, most screens first, each with its main files | `map/features.json` |
| Where things live | The stack pack's layer tags and their globs | the stack pack |
| Version notes | The top 10 curated notes (summary only) and the counts of `delta.md`'s API lists | the notes, in `delta.md`'s order; the delta facts |
| Decisions | One line per decision | `.appstein/decisions/*.md` |
| Current work | A quote of the project's own note on what is in progress | `.appstein/memory/current.md` |
| Freshness | The Appstein and Flutter versions, and how well the curated notes cover this SDK | the sync itself |

The heading is the project's name from `pubspec.yaml` (or "This project" when it can't be read). The time of the sync is in the front matter, not in the text.

Some details that are easy to get wrong:

- **Platforms** are the folders that exist among `android`, `ios`, `linux`, `macos`, `web` and `windows`. That is how Flutter decides which platforms a project has.
- **App ids are never guessed.** [`appIdLines`](../../packages/appstein_engine/lib/src/index/index_sources.dart) reads them from `native.json`, and anything that is not a plain found value is written ``unknown; see `map/native.json` ``.
  - Android's `applicationId` is the one in `defaultConfig`. When product flavors exist, the line says how many "may change it", because a flavor can override the id.
  - iOS's id is read per Xcode configuration (Debug, Release, Profile), because `Info.plist` holds only `$(PRODUCT_BUNDLE_IDENTIFIER)`, which is a variable and not an id. If every configuration agrees, the line shows one id; if they differ, it lists each configuration with its id. A value with a `$` anywhere in it (`$(X)`, `${X}` or `$X`) is `unknown`, because a real id can't contain one.
  - A platform folder that doesn't exist gives no line at all.
- **Features** are ordered by number of screens (most first), then by name. A row shows the feature's folder and its main files: the screens' files, then the view models' files, at most two and then `…`. A feature with neither lists its files instead. Without `features.json` the section says why ("Not available: the project map was skipped: …", or "no stack pack, so no features"). A project with the file but no features says "None found."
- **Version notes** show each note's summary only; the full text stays in `delta.md`. A note that needs a newer language version than the project's is left out, using the same test as `delta.md` (see [version-delta](version-delta.md)).
- **Decisions** are read in file-name order. The number comes from the file name (`0002-state.md` is decision `0002`), and the title and status from the file's front matter. Decisions marked `superseded` are left out. A file whose front matter can't be read is still listed, with the reason ("unreadable (it has no title)"), so a broken file is visible and not silently skipped. When `.appstein/decisions/` itself can't be listed, the section says so.
- **Current work** is shown as a Markdown quote (`> …`), so a `#` heading inside `current.md` can never become a section of INDEX.md. Lines are cut at 160 characters, and only the first 10 are shown.

## The budget

The cap is 1,500 tokens, counted as **UTF-8 bytes divided by 3**, so 4,500 bytes. Each model tokenizes differently and none of their tokenizers runs offline, so a fixed rule is the only way to get the same answer everywhere. Dividing by 3 over-counts on purpose: code-heavy Markdown costs more tokens per byte than prose, and dividing by 3 still over-estimates it, so the real count stays under 1,500.

The front matter counts too. [`indexBodyBudget`](../../packages/appstein_engine/lib/src/index/index_document.dart) subtracts the front matter's size from 4,500 to get what the text itself may use.

[`renderIndex`](../../packages/appstein_engine/lib/src/index/index_document.dart) first renders everything it is allowed to show (10 lines of current work, all decisions, 15 features, 10 notes). If that is too long, it removes **one item at a time** and renders again, in the order of spec §6.3:

1. Notes, from 10 down to 5.
2. Current work, line by line, down to none.
3. Decisions, one at a time, down to none. The **newest** are kept, because the decisions are in file-name order and the numbers grow.
4. Features, from 15 down to 5 rows.

The generic notes go first because the project's own decisions and current work exist nowhere else in view, while the other notes are one call away in `what_changed()`.

Each of the four cuts leaves a pointer to the tool that holds the rest, such as:

```text
…and 12 more notes; ask `what_changed()`.
```

(The others are ``…and N more; ask `feature()`.``, ``…and N older decisions; ask `decisions()`.`` and ``…and N more lines; ask `memory_read()`.``. While the last two tools aren't served, those pointers read ``…and N older decisions in `decisions/`.`` and ``…and N more lines in `memory/current.md`.``) Project, Rules, Where things live and Freshness are never cut: an agent must always know the versions and the layers.

**The last resort.** If the text still doesn't fit with 5 notes and 5 features, features and then notes are cut below 5, one at a time, until it fits or none are left. Without this, a very long app id or layer list could push the file over the cap with nothing left to cut. If even that is not enough, the file is written as it is: the cap is a goal that the loop works toward, not a guarantee that clamps the text.

Real sizes: a fresh `flutter create --platforms=android,ios` app, synced on Flutter 3.47.5, gave a 3,551-byte INDEX.md (10 notes shown with "…and 31 more notes", and features "None found."). The fixture app on the real SDK gave 3,951 bytes. A large synthetic project with a 4,200-byte budget came to 4,200 bytes, with 12 feature rows, 5 of 45 notes, no decisions and no current work.

## How sync builds it

```text
KnowledgeSync.run
  |-- PlatformSync, MapSync, NativeSync, _delta    the other files, in memory
  |-- _index
  |     |-- readIndexSources    pubspec, platform folders, decisions, current.md
  |     `-- renderIndex         pure: the same inputs give the same text
  `-- KnowledgeStore.locked     writeAll: ..., INDEX.md, then state.json
```

- `KnowledgeSync._index` runs **after** the other builds and reads them from memory, not from disk: the features rows from the `features.json` body, the ids from the `native.json` body, the notes the same way `delta.md` gets them, the API counts from the delta facts.
- [`readIndexSources`](../../packages/appstein_engine/lib/src/index/index_sources.dart) reads the project's own files. It never throws for them: an unreadable file or folder becomes a reason that INDEX.md prints.
- `renderIndex` is pure, so a test can check the exact text without a project on disk.
- The file is written last, just before `state.json`, so `state.json` still lists exactly what was written.
- **A skipped map still gives an INDEX.md.** The features section says "Not available: the project map was skipped: …" with the reason, and the version notes say that `delta.md` has no API lists this time. An agent then knows why instead of finding an empty page.

## Freshness and the input hash

INDEX.md's input hash covers:

- the input hash of every other generated file it summarizes (the platform files, `delta.md`, the map files and `native.json`), so a change to any of them changes it;
- `pubspec.yaml`, for the name;
- the list of platform folders;
- each decision file's bytes, by name (an unreadable one is hashed as `unreadable:` and its reason);
- `memory/current.md`'s bytes;
- the packs' ids and versions;
- the Appstein and format versions.

The hash is stored in INDEX.md's front matter, so any change to an input rewrites the file, even when no visible line changes: any Dart edit (through the map's hash), a decision's body, or a `pubspec.yaml` change that keeps the name. Syncing again with nothing changed writes no byte, `generatedAt` included. A hand-edited or damaged INDEX.md is put back, like every generated file (see [knowledge-store](knowledge-store.md#three-rules-every-generated-file-follows)).

## Tests

- **Sources:** `packages/appstein_engine/test/index/index_sources_test.dart`: the app id rules, the feature order and main files, decision parsing (every reason a file is unreadable), the lines of `current.md`, and what the input list covers.
- **Rendering:** `packages/appstein_engine/test/index/index_document_test.dart`: the exact text, the cut order and the pointers, and the large project that has to fit.
- **Sync:** the `INDEX.md` group in `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`: it is written, it is stable across syncs, a hand edit is put back, a skipped map still gives one.
- **Real SDK:** `packages/appstein_engine/test/integration/map_real_sdk_test.dart` syncs the fixture app on the real Flutter SDK and checks INDEX.md's size against the cap.

See [testing](testing.md#the-fixture-app-and-goldens).
