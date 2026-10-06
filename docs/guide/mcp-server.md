<!-- covers:
packages/appstein_engine/lib/src/mcp/**
packages/appstein_protocol/lib/src/mcp/**
-->

# The MCP server

`appstein mcp` lets an agent ask Appstein questions while it works. Instead of reading files or running `appstein sync` and parsing the output, the agent calls a tool such as `where_is` and gets a small, structured answer. It also lets the agent record a decision or the task it is working on. This page explains what the server does on each call, and the rules behind each tool. The design is in [spec §8](../superpowers/specs/2026-09-29-appstein-design.md#8-mcp-server).

## What it is

The agent starts `appstein mcp` as a child process and talks to it over **stdio**: one JSON-RPC message per line on stdin, one on stdout. When the agent closes stdin, the server exits. Nothing but protocol messages may go to stdout, so startup problems go to stderr (see [cli](cli.md#appstein-mcp)).

It serves twelve tools. Seven read the generated knowledge:

| Tool | Answers |
|---|---|
| `overview` | The project's `INDEX.md`, the page to read first |
| `where_is` | Which files and symbols match free text such as "login screen" |
| `feature` | Everything in one feature: screens, view models, repositories, services, models, routes, tests |
| `route` | The go_router route for a path, with its screen and feature |
| `check_api` | Whether an API is deprecated or removed for this project |
| `what_changed` | The curated notes, and how many deprecated and removed APIs each library has |
| `toolchain` | The native versions that work with this Flutter, the project's values and every mismatch |

Four read and write what people and agents record (see [decisions-and-memory](decisions-and-memory.md)):

| Tool | Does |
|---|---|
| `decisions` | Reads the project's decisions: all in force, by words, or for one file |
| `record_decision` | Adds a decision, replaces one, or accepts a proposed one |
| `memory_read` | Reads the task in progress and the lessons |
| `memory_write` | Replaces the task in progress, adds a lesson, or finishes the task |

One runs the verifier:

| Tool | Does |
|---|---|
| `verify` | Checks the project against its knowledge and returns the findings (see [`verify`](#verify) below and [verify](verify.md)) |

The spec lists one more tool. `package_check` comes in slice 1d.4, with the package gate. This page covers only what exists.

All the code is in the engine and the protocol package, so the CLI stays thin:

| Where | What it holds |
|---|---|
| [`appstein_mcp_server.dart`](../../packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart) | `AppsteinMcpServer`: each tool's registration, the queue, the freshness step and the reply |
| [`tool_names.dart`](../../packages/appstein_engine/lib/src/mcp/tool_names.dart) | `mcpToolNames`: the names of the tools served, in order. `sync` reads it too, so [INDEX.md](index-md.md) names only these |
| [`knowledge_snapshot.dart`](../../packages/appstein_engine/lib/src/mcp/knowledge_snapshot.dart) | `KnowledgeSnapshot`: reads the knowledge files a call needs. `appstein docs` and `appstein verify` read through it too, which is why it also reads `sdk.json` and `deps.json`, files no read tool asks for. `mapProblem` says why the project map can't be used (the first of its files that can't be read), the one test `docs` and `verify` share |
| [`verify_tool.dart`](../../packages/appstein_engine/lib/src/mcp/verify_tool.dart) | `verifyAnswer`: a `VerifyResult` as the tool's reply, with its sentence |
| [`tool_answer.dart`](../../packages/appstein_engine/lib/src/mcp/tool_answer.dart) | `ToolReply` and `ToolRefusal`, what a query returns |
| `where_is.dart`, `feature_query.dart`, `route_query.dart`, `check_api.dart`, `what_changed.dart`, `toolchain_report.dart` (same folder) | One pure function per tool |
| `decisions_query.dart`, `record_decision.dart`, `memory_tools.dart` (same folder) | The four decision and memory tools: the `decisions` query, the argument checks of `record_decision`, and `memory_read` and `memory_write` |
| [`tool_schemas.dart`](../../packages/appstein_protocol/lib/src/mcp/tool_schemas.dart) | Each tool's input and result schema |
| [`freshness_report.dart`](../../packages/appstein_protocol/lib/src/mcp/freshness_report.dart) | `FreshnessReport`, the `freshness` field |
| [`tool_output.dart`](../../packages/appstein_protocol/lib/src/mcp/tool_output.dart), [`json_schema.dart`](../../packages/appstein_protocol/lib/src/mcp/json_schema.dart) | `withoutNulls`, the output schema, and small schema builders |

The schemas are plain maps, so the protocol package needs no MCP library. The engine wraps them for `package:dart_mcp`.

## One call, step by step

Each tool call goes through the same steps. The tools themselves are pure functions of the knowledge files, so the same files always give the same answer.

```mermaid
sequenceDiagram
  participant A as Agent
  participant S as AppsteinMcpServer
  participant K as KnowledgeSync
  participant F as .appstein/ files
  A->>S: tools/call where_is
  Note over S: wait for earlier calls to finish
  S->>K: detect (package skills off, held cache)
  K->>F: rebuild if an input changed
  K-->>S: current, rebuilt or an error
  S->>F: KnowledgeSnapshot reads what the tool needs
  Note over S: the pure query, then withoutNulls
  S-->>A: summary text + JSON text + structuredContent
```

1. **Queue.** Calls are answered one at a time, in an in-process queue (`_oneAtATime`). Two calls at once would both start a sync. The file lock can't stop that, because on Linux and macOS an operating-system lock doesn't exclude the process that already holds it (see [knowledge-store](knowledge-store.md#the-lock-and-why-files-are-renamed-into-place)).
2. **`detect`.** The server builds a `KnowledgeSync` and calls `detect`, as `appstein sync --detect` does (see [incremental-sync](incremental-sync.md)). It builds a new one for every call, from the `appstein.yaml` as it is then. Package skills are off, and the analyzer cache is held in memory between calls.
3. **Snapshot.** A new `KnowledgeSnapshot` reads each knowledge file the first time the tool asks for it. If a file is missing or damaged, the tool answers with a refusal that names the file and says to run `appstein sync`.
4. **The query.** The tool's function turns the files and the arguments into a `ToolReply` (a result and a summary sentence) or a `ToolRefusal` (a message).
5. **The reply.** `withoutNulls` drops every null. The server adds `summary` and `freshness` to the result and sends it as `structuredContent`, plus two text blocks: the summary with a sentence about freshness, and the same structured result as JSON text. A refusal, or any exception inside a query, becomes a result marked `isError` that says why, and the server keeps running. An error has no structured content, so its one text block ends with the same sentence about freshness; an agent then knows whether "no feature is named X" was said from current knowledge. The one exception is arguments that don't fit the tool's input schema (a missing `query`, say): `package:dart_mcp` refuses those before the tool runs, so no sync happened and the reply has no freshness.

**The held cache.** Rebuilding after an edit needs the analyzer's cache, a file of about 57 MB at 200 files (see [incremental-sync](incremental-sync.md#the-analyzer-cache)). Reading it from disk before every rebuild would waste time, so `KnowledgeSync` takes an optional `heldCache`. A [`HeldAnalyzerCache`](../../packages/appstein_engine/lib/src/map/analyzer_cache.dart) hands the cache to a sync (`take`) and receives it back afterwards (`keep`). What it keeps is `AnalyzerCache.settled()`: only the entries the last run used, as if it had been saved and read again. So the memory use matches the file. A cache file that another process wrote in between isn't read. That costs a few cache misses, never wrong knowledge.

## Freshness

Every reply says whether the knowledge was up to date. There are three states:

| State | When | What the reply carries |
|---|---|---|
| `current` | Nothing the knowledge reads has changed | Just the state |
| `rebuilt` | The server rebuilt first: there was no sync yet (a fresh clone), an input changed (an edit, a new package version), or a file was hand-edited or deleted | `because` (the reasons), `changed` (the files, at most 20, then `moreChanged`) and `mapSkipped` when the project map couldn't be built |
| `stale` | The server couldn't sync, so it answered from the files on disk | `problem`, and `fixHint` when something can be done |

`stale` happens when:

- another process holds the knowledge lock past its timeout (`another sync is running and holds the lock`);
- the sync fails, for example with no usable Flutter SDK, or a write error;
- `appstein.yaml` is invalid. The next call reads it again, so fixing the file is enough.

If there is no knowledge file to answer from at all, for example a project that was never synced and whose first sync fails, the reply is an error that says what to do. A stale answer needs older files to exist.

**Why the server always calls `detect`.** A server that read files once at startup would answer from knowledge that went out of date with the first edit. The agent can't tell, and a wrong answer given with confidence is worse than a slow one. `detect` costs about 77 ms when nothing changed (see [incremental-sync](incremental-sync.md#the-idea)), so asking every time is cheap. When something did change, the rebuild takes about a second, and the reply says so.

## Each tool

### `overview`

No input. Returns `index` (the body of `INDEX.md`, without its front matter) and `generatedAt`. The knowledge's freshness is in the `freshness` field of the same reply.

### `where_is`

Input: `query`, free text. The query is cut into lowercase words at camelCase humps and at every character that isn't a letter or a digit, so `LoginScreen`, `login_screen` and `login_screen.dart` all give `login`, `screen`. The spec's ranking has no embeddings, so it is predictable.

Four kinds of candidate are matched, and each word scores by the kind it matched:

| Candidate | Matches a word of | Score per word |
|---|---|---|
| Symbol | its name, or its whole name | 5 |
| Route | its path, or its screen's name | 4 |
| Feature | its name | 3 |
| File | its path | 2 |

A word of four or more letters that matches nothing exactly scores 1 when it is at most two edits from a word of the candidate, so `bookng` still finds `booking`. Words of three letters or fewer never match this way, on either side, because almost any short word is two edits from another: without that rule `list` would be "close to" the `lib` in every file path. A candidate's score is the sum over the query's words, and ties go to the name and then the file. `total` says how many candidates matched in all.

**Which ten are listed.** Not simply the ten best scores. A symbol word is worth 5, so a word that appears in ten or more symbol names (`booking` in the fixture app) would fill every place with symbols, and the agent would never see that there is a `booking` feature, a `/booking` route and a folder of files. So `_listed` first takes the best feature, the best route and the best file that matched, when there are any, then fills the remaining places with the best of the rest, and lists the ten by score. Nothing is listed twice, and a query with fewer than ten matches lists them all.

Each match has the reason for every word that matched, and the fields the map has for its kind: a symbol has its file and line, layer, feature and doc-comment summary; a route its file and line, and its feature; a file its layer and feature; a feature its folder.

### `feature`

Input: `name`, the feature's folder below `lib/ui/`, such as `auth/login`. These forms work: `auth/login`, `/auth/login/` and `lib/ui/auth/login`. The reply is the feature's map entry plus the routes that build its screens. An unknown name is refused with the closest known name (by edit distance) and the first 20 feature names.

### `route`

Input: `path`. A leading slash is added when it is missing, a trailing slash, a query (`?…`) and a fragment (`#…`) are ignored. An exact path wins. Otherwise a concrete path matches a go_router pattern with the same number of segments, where a `:parameter` segment matches any non-empty segment: `/booking/42` matches `/booking/:id`. The reply's `match` says `exact` or `pattern`.

Routes whose path the map couldn't work out are never matched; the refusal says how many there are. For each route the reply gives its screen, feature, parent, nested routes and whether it redirects.

**A redirect is never a dead end.** In the first trial of Appstein, an agent asked what `/booking/42` shows, was told "no screen recorded; it redirects", and answered "it goes elsewhere" without opening the router. An agent stops looking when the map answers, so the reply now always leads somewhere:

- when the map knows the target (see [project-map](project-map.md#routes)), the route has `redirectsTo`: the path, plus the screen and feature of the route at that path. The summary reads "It redirects to `/booking`, which shows screen `BookingScreen` in feature `booking`.";
- when the route at that path has a redirect of its own, `redirectsTo` says so (`redirect: true`, with that route's `file` and `line`), and the summary doesn't call its screen the answer: "It redirects to `/home`, which has its own redirect, so it may not be where the path ends: read …". The tool doesn't follow the chain itself;
- a route can have both a builder and a redirect. Its screen is then reported as "shown only when its redirect lets the path through";
- when the route redirects and the map doesn't know where, the route has `redirectHint`, which names the file and line to read;
- when a router has its own `redirect:` (a sign-in check, typically), `redirectNote` names that router's file and line, on every reply. The map doesn't record when or where a router redirects.

### `check_api`

Input: `name`. The agent may write the name the way it appears in code. These forms are understood:

| Written | Understood as |
|---|---|
| `WillPopScope`, `Color.withOpacity` | a class or function, or a member with its class |
| `withOpacity`, `.withOpacity`, `color.withOpacity` | a member name alone |
| `withOpacity(0.5)` | the same, with the argument list dropped |
| `Text()` | the unnamed constructor `Text.new`, or the class `Text` |
| `Text.new(textScaleFactor)`, `Text(textScaleFactor)`, `Text(textScaleFactor: 1.2)` | a parameter of that constructor (a named argument is the parameter of that name) |
| `MaterialStateProperty<Color>.all`, `withOpacity<T>` | the same name without its type arguments (nested ones too) |
| `textScaleFactor` | a parameter name on its own |
| `package:flutter/material.dart` | a library (matches a moved library) |

A setter matches with or without its `=`.

**Matching.** The name is compared with the entries of `delta.json`. An entry whose name equals the query matches *exactly*. Only when nothing matches exactly does it fall back to *looser* matches: the same member name under any class (the delta lists an inherited member under the class that declares it, and an agent usually writes `color.withOpacity`, not the declaring class). The summary then names the entry that matched and its library, such as "`color.withOpacity` is deprecated in `Color.withOpacity` (dart:ui)" for a query of `color.withOpacity`, so the agent can judge whether it is the one it meant. **The class check.** The delta lists only elements that carry their own `@Deprecated`, so the members of a deprecated class (`MaterialStateProperty.all`) or its constructors (`WillPopScope.new`) are not in it. When nothing matches as deprecated or removed and the query has two or more segments, `check_api` also looks up the part before the last segment (for `X.new`, that is `X`). A class that is deprecated (kind `use`) or removed makes the member answer the same way, and the summary names the class and its library: "`MaterialStateProperty.all`: its class `MaterialStateProperty` is deprecated (package:flutter): Use WidgetStateProperty instead." A class whose deprecation is of another kind forbids only that one use, so its members stay `ok`. When a query names a member that owns a deprecated parameter, the parameters are listed in `matches` without changing the status.

**Statuses.** `removed` beats `deprecated`, and `deprecated` beats `ok`:

- `removed`: a removed API matches. Code that uses it doesn't compile.
- `deprecated`: an API matches whose deprecation is of kind `use`, the plain `@Deprecated`.
- `ok`: neither.

**Deprecation kinds.** Dart has seven (see [version-delta](version-delta.md#what-the-imports-expose-means)). Only `use` makes the status `deprecated`, as the plain annotation says not to use it at all. The other six forbid only one thing: `implement`, `extend`, `subclass`, `instantiate`, `mixin` and `optional` (always pass this argument). For those the status stays `ok`, and the summary adds the rule, such as "Its deprecation forbids only this: don't implement it." Changed APIs, moved libraries and parameters of a member are listed in `matches` and don't change the status either.

**What `ok` means.** Nothing the project imports deprecates or removes the name. It does **not** say the name exists: a made-up name is also `ok`. The reply says so in `meaning`, because Dart's own MCP server (`dart mcp-server`) runs next to ours and its analyzer answers that question (spec §8).

The reply also lists the curated notes whose `avoid` text names the identifier as a whole word, each with its source. When the delta's API lists couldn't be collected (`delta.json` has `missing` instead), only the notes are checked, and `incomplete` says so.

### `what_changed`

Input: optional `since` (a Flutter version such as `3.27`) and optional `library` (such as `package:go_router`). `since` narrows only the notes. A `since` older than the delta's baseline starts at the baseline, and the summary says so. Notes that need a newer language version than the project's come back in `laterNotes`.

Without `library`, the reply holds the notes and, per library, the **counts** of deprecated, removed, changed and moved APIs. It lists no entries. The reason is size: on a Material app the delta holds about 354 deprecated and 355 removed entries, roughly 35,000 to 45,000 tokens. Claude Code warns about a tool output above 10,000 tokens and cuts it above 25,000 by default, so a full list would be lost exactly when it matters. `check_api` answers for one name, and `library` lists one library's entries in full.

`library` accepts `package:go_router`, `go_router`, or a library file URI such as `package:flutter/material.dart`, which is the same library as `package:flutter`: entries are grouped by package, and a moved library counts under its package. An unknown library is refused with the libraries that do have entries.

### `toolchain`

No input. It returns the native versions that work with this Flutter (`valid`, from `toolchain.json`), the project's current values with where each was found (`current`, from `native.json`), and the mismatches. Only thresholds Flutter itself applies are used:

| Value | Error | Warning |
|---|---|---|
| Gradle, AGP, KGP | below the version where Flutter's Gradle plugin fails the build | below the version where it warns, or above the newest this Flutter knows |
| `minSdk` | below Flutter's build-check threshold | below its warning threshold |
| `compileSdk` | – | below Flutter's minimum |
| iOS deployment target | – | below the SDK template's |

`targetSdk` and the NDK version are shown but have no threshold. A value that `native.json` records as `unknown`, or whose platform pack failed, is listed in `notComparable` with its reason instead of being guessed. Versions are compared as dotted numbers, and a `-rc1` suffix is ignored. Without `native.json`, only the valid set is returned and the summary says so.

## Decisions and memory

These four tools work on files the project commits, not on generated knowledge. The formats and rules are on their own page, [decisions-and-memory](decisions-and-memory.md); this section says what each tool takes and returns.

### `decisions`

Input: optional `topic`. The topic decides how the tool searches:

| Topic | Mode | Returns |
|---|---|---|
| none, or blank | `all` | Every accepted and proposed decision, in file-name order, and a count of the superseded ones |
| an absolute path; or no white space, a `/`, a `\` or a file extension, and a first part that exists in the project | `path` | The decisions in force whose `paths` cover that file. `withoutPaths` counts those that list no paths, since they apply everywhere |
| anything else | `words` | The decisions that mention the words, best first, superseded ones included and marked with `supersededBy` |

**Path mode** exists for one moment: just before an agent edits a file. A Windows path (`lib\ui\home\x.dart`) and a leading `./` are accepted. An absolute path, which is what an agent usually holds, is read from the project folder; one outside the project is covered by nothing, and the summary says it is outside. A pattern covers a file when the glob matches it, or when the pattern names the file or a folder above it, so `lib/routing` covers `lib/routing/router.dart`. A folder is covered when a file in it would be.

**Telling a path from words.** `CI/CD`, `Node.js` and `go_router/provider` have a `/` or a dot but are words. So a topic counts as a path only when its first part (`lib`, `pubspec.yaml`) is a file or folder the project has; a file that doesn't exist yet in an existing folder still counts. Otherwise the topic is searched as words. A wrong guess here would answer "no decision covers it" about something that was never a file. A pattern that isn't a valid glob covers nothing and is named in `problems`.

**Word mode** scores each word by the best place it is found: the decision's number 5, its title 3, a path 2, its reason 1. A decision's score is the sum. Ties go to decisions in force, then to the higher number.

Every reply also lists the unreadable files and the numbers that two files use, whatever the mode, because an agent that never sees them would trust an incomplete list. When a decision's own status line differs from how readers count it, `statusInFile` shows the file's word.

### `record_decision`

Input: `title` and `why` for a new decision, with optional `status` (`proposed` or `accepted`), `paths`, `checks` and `supersedes`; or `accept` alone, with the number of a proposed decision. A number may be written `"0002"`, `"2"` or `2`: the schema gives those two fields no type, because agents send all three and `package:dart_mcp` refuses an argument of the wrong type before the tool runs. The two shapes can't be told apart by a JSON schema that every client accepts, so the schema requires nothing and `_request` in `record_decision.dart` checks the shape and says what is wrong.

The reply has `action` (`added`, `replaced` or `accepted`), the `decision` as it now reads, the `superseded` decision for a replacement, and a `warning` when the old file's status line couldn't be changed. The summary of a proposed decision tells the agent how to accept it later.

### `memory_read`

No input. Returns `current` (the whole text of `memory/current.md`, absent when there is no task), the newest 50 `lessons` in the file's order, and `olderLessons`, how many more the file holds. It never refuses: a file that can't be read is named in `currentProblem` or `lessonsProblem`.

### `memory_write`

Input: `kind` (`current`, `lesson` or `complete`) and `text`. The reply names the file written, the lesson line and whether it was `added`, and for `complete` the file that was `cleared`.

### What a write tool does differently

A read tool runs the freshness step, then answers. A write tool (`_writeTool` in the server) runs it, writes, and runs it **again**:

```mermaid
sequenceDiagram
  participant A as Agent
  participant S as AppsteinMcpServer
  participant K as KnowledgeSync
  participant F as .appstein/
  A->>S: tools/call record_decision
  S->>K: detect
  S->>F: take the lock, write decisions/0004-….md
  S->>K: detect again
  K->>F: rewrite INDEX.md (a decision file changed)
  S-->>A: the decision, freshness "rebuilt"
```

A decision file and `current.md` are inputs of `INDEX.md`. Without the second check, `INDEX.md` on disk would miss the new decision until the next call, and an agent that has it in view would read an old list. The reply states the second freshness, so after a decision or a new task it says `rebuilt`, because `INDEX.md` was out of date. A lesson changes no input of `INDEX.md`, so that reply says `current`.

A refused write runs no second check and states the first freshness. Almost every refusal means nothing was written. The exception is finishing a task when `current.md` can't be deleted: the lesson was already saved, and the message says so.

## `verify`

Input: `scope`, `fast` or `full`. The reply is what `appstein verify --format json` prints: `findings`, `summary` (the counts), `suppressed`, `activeSuppressions` and `notRun`, plus `freshness`. What the checks are is in [verify](verify.md).

`_verify` in the server differs from the other tools in three ways:

- **The knowledge is refreshed once.** The freshness step every call runs is the refresh `verify` needs. The server hands its result to `runVerify` (`KnowledgeRefresh.fromFreshness`) and reuses the sync it built, so nothing is synced twice.
- **Stale knowledge is a finding, not an error reply.** Another tool with no file to answer from returns an error. `verify` always has an answer: `knowledge.stale` as an error finding, the checks that could not run in `notRun`, and a `freshness` marked `stale`. An agent that asks "may I say done?" gets "no, and here is why".
- **`summary` is the counts**, an object, where every other tool's is a sentence (see [below](#replies-for-claude-code)). The sentence (`Full verify: 1 error, 2 warnings, 0 info. Fix the error before the task is done.`) is in the reply's text.

It reads `appstein.yaml` on every call, for `verify.severity` and `suppressions`. An invalid file is an error reply that names it, and so is a sync that can't be built: without packs there is no list of checks. A check that throws becomes the usual "Appstein failed to answer" error.

## Replies for Claude Code

A reply holds the same result three times, because clients read it differently:

- the structured result, as `structuredContent`;
- the same result as JSON text;
- a short sentence, `summary`, plus a sentence about freshness.

**Why `summary` and `freshness` are inside the structured result.** Claude Code shows the model only `structuredContent` when a tool returns it, and drops the text blocks ([claude-code#55677](https://github.com/anthropics/claude-code/issues/55677)). A summary that lived only in the text would never reach the model. So every output schema is the tool's result schema plus `summary` and `freshness` (`toolOutputSchema`), and the server adds both to the result.

**One exception: a result with a `summary` of its own keeps it.** `verify`'s result already has `summary`, the counts of errors, warnings and info, because spec §9.3 gives the tool the same JSON as `appstein verify --format json`. `toolOutputSchema` and the server leave it alone, so in Claude Code the model sees the counts and the findings, and not the sentence. The sentence adds nothing the counts and the tool's description don't say.

**Why replies never hold null.** `withoutNulls` removes null values from maps and lists at every depth, so a missing value is an absent key. That keeps the schemas simple: none uses a type array such as `["string", "null"]`, which not every client's schema checker handles, and an optional field is just one that isn't `required`.

## Testing it

| Test | What it proves |
|---|---|
| `packages/appstein_engine/test/mcp/where_is_test.dart`, `feature_query_test.dart`, `route_query_test.dart`, `check_api_test.dart`, `what_changed_test.dart`, `toolchain_report_test.dart` | Each query on its own, on the fixture app's golden map files (see [testing](testing.md#the-fixture-app-and-goldens)) and a sample delta |
| `packages/appstein_engine/test/mcp/knowledge_snapshot_test.dart` | A missing, unreadable or damaged file gives a `problem` that names it |
| `packages/appstein_engine/test/mcp/decisions_query_test.dart`, `record_decision_test.dart`, `memory_tools_test.dart` | The four decision and memory tools on real folders (see [decisions-and-memory](decisions-and-memory.md#testing-it)) |
| `packages/appstein_engine/test/mcp/appstein_mcp_server_test.dart` | The server through an in-process client: the tool list and schemas, the first call syncing a new project, an edit picked up before the next answer, bad input, three calls at once answered in turn, a lock held by another process, a failing sync, a damaged file, an invalid `appstein.yaml`; a recorded decision and a task in progress showing in `INDEX.md` when the reply arrives; `verify` in both scopes, with a suppression from `appstein.yaml`, a bad `scope`, knowledge that can't be refreshed (a finding, and the sync built once) and an invalid `appstein.yaml` |
| `packages/appstein_engine/test/mcp/verify_tool_test.dart` | `verifyAnswer`: the result matches the schema, and each form of the sentence |
| `packages/appstein_engine/test/mcp/mcp_stdio_test.dart` | The real thing: a new process over real stdio, in a folder whose name has a space and an umlaut. Every tool answers, the decision and memory files it wrote are on disk, and stdout holds only protocol messages |
| `packages/appstein_cli/test/mcp_command_test.dart` | The command: it serves until the client closes, writes nothing to its output sink, re-reads `appstein.yaml` on every call, exits 3 outside a project, and its sync factory turns package skills off and shares one held cache |
| `tool/measure_sync.dart` | The speed target (below) |

**The timing table.** After the sync rows, [`tool/measure_sync.dart`](../../tool/measure_sync.dart) starts one `appstein mcp` process on the 200-file app, with fresh knowledge. It talks to the server with a small JSON-RPC client over the process's stdin and stdout. The first call starts the server and isn't counted. Then it calls each of the seven tools that read generated knowledge three times (the decision and memory tools aren't timed yet) and prints a table with the median and the three times. Spec §15 sets the target, MCP answers under 1 s from fresh knowledge, and the tool fails when a median reaches it, or when a call returns an error. Only the 200-file app is measured. See [ci](ci.md#measure).

**Trying it by hand.** Compile the command, then send it an `initialize` request:

```powershell
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o <out>
```

Pipe a JSON-RPC `initialize` message to `<out> --project <app> mcp` and it answers with its name, version and instructions. `fvm dart packages/appstein_cli/bin/appstein.dart --project <app> mcp` works too, only slower to start. On Windows, Defender sometimes quarantines a freshly compiled, unsigned Dart executable in a temporary folder. That is a false positive: compile somewhere else or use the second command. The server exits when stdin closes.
