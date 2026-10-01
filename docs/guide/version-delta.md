<!-- covers: packages/appstein_engine/lib/src/delta/** -->

# The version delta

`appstein sync` writes `.appstein/platform/delta.md` (spec §6.4). It's a cheat sheet an agent reads before it writes code: which APIs of the installed Flutter, Dart and the project's packages are deprecated, removed or moved, and what to use instead, plus Appstein's curated notes. This page explains where each line comes from and why it is built this way. The facts behind each decision were checked against Flutter's and Dart's own files; they're listed in the [slice 1b.5 plan](../superpowers/plans/2026-10-01-slice-1b5-version-delta.md#decisions-made-while-planning-for-the-owners-review).

## What the file holds

| Section | Holds | From |
|---|---|---|
| Notes | Appstein's curated notes since the baseline (`delta.baseline` in `appstein.yaml`, `3.16` by default), most important first | `notes/*.yaml`, compiled in (see [knowledge-store](knowledge-store.md#the-curated-notes)) |
| Needs a newer language version | Notes the project can't use yet, because its language version (the lower bound of `environment: sdk:`) is older than the note's | the same notes |
| Deprecated | Every deprecated declaration, member and parameter the project's imports expose, with the library's own message | `Deprecated` annotations, read through the analyzer |
| Removed | APIs or parameters that are gone (`removed`: code that uses them doesn't compile), or still there with a migration that changes how they're used (`changed`), with the migration's title | `fix_data` migrations |
| Moved libraries | Libraries a migration moves, such as `package:flutter/material.dart` to `material_ui` | `fix_data` migrations with a `library:` |
| Not read | Migration files Appstein couldn't read, and why | |

Deprecated and Removed are grouped by package (`dart:core`, `package:flutter`, `package:go_router`), never by Flutter's private `src/` files, which no one should import. Each line quotes the library. Appstein adds only the section intros, the words `removed` and `changed`, and the rule of each deprecation kind. It also puts a full stop after a message or a migration title that has none when more text follows, and it joins a title, an unread reason or a skip reason onto one line, so a line break can't break a Markdown list. The curated notes are printed as written.

## Why every deprecation is listed, whatever its age

The baseline limits only the curated notes. Deprecations and migrations are listed however old they are, for two reasons:

- **Their age can't be read from the SDK.**
  - A deprecation message names a development build, not a release: `WillPopScope` says "deprecated after v3.12.0-1.0.pre", but it first shipped deprecated in stable 3.16, and `v3.16.0-17.0.pre` first shipped in 3.24.
  - A `fix_data` date is when the fix was written, so dates don't even follow release order.
  - Only Flutter's git tags know, and reading them takes minutes.
- **Hiding old ones would backfire.** `verify` fails on every deprecated use (spec §9.1), so a cheat sheet that left out the 115 deprecations older than 3.16 would let an agent write code our own check then rejects.

The list never reaches *newer* than the installed SDK: it is read from the user's own SDK and packages.

## What "the imports expose" means

- **Deprecations:**
  - [`collectDelta`](../../packages/appstein_engine/lib/src/delta/delta_collector.dart) walks the export namespace of every library the project imports (`dart:core` included, since every library imports it), the way the analyzer's `deprecated_member_use` sees them;
  - it notes each declaration, member, constructor and parameter that carries a `Deprecated` annotation;
  - a deprecated top-level variable or constant is listed under the variable's name (the analyzer makes up a getter and a setter for it, and those carry no annotation); a top-level setter is named with its `=`, like a member setter;
  - a member inherited from a private superclass is listed under the public class that exposes it;
  - a declaration in a private `dart:` library (`dart:_internal`, `dart:_http`) is grouped under the public `dart:` library the walk reached it through, such as `dart:io`, because an agent can't import `dart:_http`;
  - `show` and `hide` on imports are not applied.
- **The project's own libraries are left out, decided by URI.** A library is the project's own when its URI is `package:<the app's name>/…`, or a `file:` URI under the project folder. Where its files sit is not the test. A package inside the project folder (a path dependency, a project-local pub cache, or a `pub get` that went through `.fvm/flutter_sdk`) still counts as a package and is covered. A library reached by any other `file:` URI is skipped, so that no machine path reaches `delta.md`.
- **Migrations:**
  - a migration counts when the project imports one of its libraries **directly**: the rule `dart fix` uses (`ElementMatcher` in the Dart SDK's analysis server);
  - its element is then looked up in **every** library the migration lists, and its kind is matched loosely, as `dart fix` does: for a member, `constant`, `field`, `getter`, `method` and `setter` all match (Flutter's own file calls the getter `Color.opacity` a `method`); top-level kinds match the same way. Classes, constructors and the other kinds match exactly;
  - a listed library the project doesn't import is looked up through the analysis that is still open (`getLibraryByUri`), even when no import of the project reaches it. An app that imports only `widgets.dart` and has no widget test never reaches `material.dart` through its imports, yet `MaterialState` is still there and must not be called removed;
  - no listed library has it, and each one was resolved: `removed`. A listed file that is missing from a package the project has counts as a library that exports nothing;
  - only a listed library the project doesn't import has it: the migration is left out. It isn't removed, and the delta lists only what the imports expose; importing that library rebuilds the delta;
  - a listed library can't be resolved at all (a package the project doesn't depend on, an unknown `dart:` library), and no other listed library has the element: whether it exists can't be told, so the migration is left out. It is never called `removed` on a guess;
  - the project's imports have it, and the migration names old parameters (it removes or renames them): each parameter gets its own line, named the way the Deprecated section names parameters. A parameter that is gone is `removed` (`Stack.new(overflow)`: Stack's constructor is fine, its `overflow` is gone). One that is still there and deprecated gets the migration attached to its deprecation line. One that is still there and not deprecated is `changed`, unless the element itself is deprecated, which then gets the migration attached;
  - the project's imports have it, the migration names no parameter, and the element is deprecated: the migration is attached to that deprecation line ("`dart fix` migrates it: …"). The attachment never renames an entry;
  - the project's imports have it, the migration names no parameter, and it isn't deprecated: `changed`. The title says what changed.

The Removed section's intro says what each word means: `removed` is gone, and code that uses it doesn't compile; `changed` still exists, and `dart fix` changes how it's used. So an agent reading "`Navigator.of(nullOk)`: removed. Migrate from 'nullOk'." knows that `Navigator.of` itself is fine.

Dart has seven kinds of deprecation (`dart:core`'s `Deprecated` constructors). The delta words each one:

| Annotation | The line says |
|---|---|
| `@Deprecated(…)`, `@deprecated` | the message (or "deprecated, with no message.") |
| `@Deprecated.implement` | don't implement it. |
| `@Deprecated.extend` | don't extend it. |
| `@Deprecated.subclass` | don't extend or implement it. |
| `@Deprecated.instantiate` | don't create instances of it. |
| `@Deprecated.mixin` | don't mix it in. |
| `@Deprecated.optional` | always pass this argument: it will become required. |

So `RegExp` (`@Deprecated.implement`) appears as "don't implement it", and using `RegExp` stays fine.

## Where the migrations come from

[`parseFixData`](../../packages/appstein_engine/lib/src/delta/fix_data.dart) reads the files `dart fix` reads:
- each imported package's `lib/fix_data.yaml` or `lib/fix_data/**.yaml` (Flutter uses the folder, go_router the single file);
- the Dart SDK's `lib/_internal/fix_data.yaml`.

Relative URIs (`material.dart`) resolve against the package. An empty file (Flutter ships `fix_template.yaml` empty) has no migrations. A broken file, or one that isn't valid text, is listed under "Not read" and the rest of the delta is kept: a package's bad file never fails `sync`. Names in the file are package URIs (`package:delta_kit/fix_data/fix_broken.yaml`), never machine paths. The one exception is the "incomplete Dart SDK" reason, where the SDK's path is the fact you need to act on.

## How sync builds it

```text
KnowledgeSync.run
  |-- PlatformSync.build     sdk.json, toolchain.json
  |-- MapSync.build          ... the map, then, while the analysis is open:
  |     collectDelta         deprecations + migrations -> DeltaFacts
  |-- deltaNotes             the notes from the baseline up to this SDK
  |-- renderDelta            -> GeneratedFile.markdown('platform/delta.md')
  `-- KnowledgeStore.locked  writeAll: platform files, delta.md, map files, state.json
```

- [`renderDelta`](../../packages/appstein_engine/lib/src/delta/delta_document.dart) is pure: the same inputs give the same text, and a golden file pins it.
- **When the map is skipped** (the packages can't be fetched, or a broken `pubspec.lock`), there is no analysis, so `delta.md` holds only the notes and a line saying why the rest is missing. The Flutter SDK has no package config of its own, so nothing can be resolved without the project's packages.
- **When only collecting the delta fails** (an analyzer internal or a bug), `sync` does not fail and the map is not lost. [`MapSync`](../../packages/appstein_engine/lib/src/map/map_sync.dart) catches the error and keeps it in `MapReport.deltaError`, with its type in `MapReport.deltaErrorType`. The map and platform files are written. `delta.md` holds the notes and says: "Deprecated and removed APIs are missing: Appstein couldn't collect them because of an internal error (StateError). Please report it." It names only the error's type, because the message may hold a machine path. It doesn't say "Fix that", because the user can't: it is Appstein's bug. The sync output shows the whole error once, under `Version delta: deprecated and removed APIs are missing because of an internal error in Appstein. Please report it, with this error:` (see [cli](cli.md#appstein-sync)). A sync never fails because of the delta.
- The file is Markdown with its metadata in front matter (see [knowledge-store](knowledge-store.md#three-rules-every-generated-file-follows)).

## Freshness

`delta.md`'s input hash covers:
- the map's own input hash: the project's Dart files, `pubspec.yaml`, the lock file (so every package version), `analysis_options.yaml`, the Flutter version and the packs. When there are no facts, the text `skipped:` and the reason are hashed instead: the map's skip reason, or, when the collector failed, `internal error (<the error's type>)`, never the error's message, so no machine path is hashed and the same failure on another machine gives the same hash;
- the notes files;
- the baseline;
- the language version.

So a new package version, a new Flutter, an edited import or a new baseline rebuilds it. A changed baseline rewrites only `delta.md`: the map files keep their bytes.

## Tests

- **Parser:** `packages/appstein_engine/test/delta/fix_data_test.dart`, with entries copied from Flutter's and go_router's real files.
- **Collector:** `packages/appstein_engine/test/delta/delta_collector_test.dart`, on the `delta_kit` stand-in package in `packages/appstein_engine/test/fixtures/apps/stubs/delta_kit/`. That package was made for these tests: one of each kind of deprecation (a top-level variable, constant and setter too), a private superclass, a hidden class, and migration files that are removed, changed, attached, out of scope, a library move, broken and empty. Some migrations name old parameters: one that is gone (`removed`), one that is deprecated (attached) and one that is still there (`changed`). `more.dart` is a library no import of the test app reaches: a migration whose element only it exports is left out, not `removed`, and so is one that lists a package the app doesn't have (`missing_kit`). It also checks that an app importing `dart:io` has no group starting with `dart:_`, and that a file that isn't valid UTF-8 lands under "Not read".
- **Renderer:** `packages/appstein_engine/test/delta/delta_document_test.dart`, against `fixtures/apps/goldens/delta.md.golden`.
- **Sync:** `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`, including a collector that throws.
- **Real SDK:** `packages/appstein_engine/test/integration/map_real_sdk_test.dart` checks lines that hold on both Flutter 3.44 and 3.47 (`WillPopScope`, `Stack.overflow` and `Stack.new(overflow)`, go_router's `location`), a 1,500-line ceiling, and no duplicate lines.

See [testing](testing.md#the-fixture-app-and-goldens).
