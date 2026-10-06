# Slice 1c.2: Decisions and Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Knowledge layers 3 and 4 work end to end: an agent reads the project's decisions and memory through `decisions` and `memory_read`, and writes them through `record_decision` and `memory_write`, in the spec's file formats.

**Architecture:** One decisions store reads every `.appstein/decisions/*.md` file and applies the spec's reading rules (implied superseded, duplicates, unreadable); `INDEX.md` and the tools both read through it. Writes are pure text operations (render a new record, change one `status:` line, append one lesson line) wrapped by a small IO layer that holds the existing `.appstein/.lock` and replaces files in one step. The MCP server gains a second kind of tool, a write tool, which checks freshness, writes, then checks freshness again so `INDEX.md` follows.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 through FVM), `package:yaml`, `package:glob` (new direct dependency of the engine; already resolved in the workspace through `appstein_protocol`), `package:dart_mcp` 0.5.2, `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §6.1, §6.3 (item 2), §6.7, §6.8, §8 (Writes paragraph and the four table rows), §15 (Concurrency). The spec text for this slice was approved by the owner and committed as `b619f97`.

## Owner decisions (2026-10-06)

1. An agent's decision is `proposed` unless the agent passes `accepted`, which it may do only when the user agreed in the conversation.
2. `memory_write` with `kind: complete` needs the agent's summary as `text`. Appstein never writes a summary.
3. `record_decision` adds, replaces or accepts. It never rewrites an existing decision's title, reason, paths or checks.
4. The extras stay in: lookup by file path, duplicate-number reporting, and the implied-superseded rule.
5. The plan gives exact interfaces, behaviors and test cases, not every line of code (the owner's earlier choice for 1c.4; plans that guessed code were wrong in many places in 1b.4).

## Global Constraints

- Every Dart command runs through `fvm dart` / `fvm flutter`. Run each package's suite from inside the package folder, and the repo-root suite too.
- Tests first: write the test, watch it fail, then write the code.
- Never guess: a value that can't be read is reported with its reason.
- Every public API has a `///` comment. No file gets a byte order mark (the BOM gate runs before every commit).
- New files are written with `\n` line endings and UTF-8 without a BOM. An edit to an existing file keeps that file's line endings, BOM and every byte it doesn't change.
- Schemas live in `appstein_protocol`; the engine has no command-line code.
- No platform or stack knowledge is added outside the packs (principle 3 debt moves in 1d).
- Decision checks are stored, never run: `stack.provider`, `paths.exist` and `decision.drift` are slice 1d.
- The `lessons.md` over-200-lines finding is slice 1d. `docs/app/decisions.md` is slice 1c.3.
- Dates are the machine's local date as `yyyy-MM-dd`, from an injected clock.
- Windows is first-class: paths with spaces, drive letters, `\r\n` files, files held open.

## Review Focus

1. **A decision file written by hand in a shape the writer never produces** (quoted status, `\r\n` endings, a BOM, comments after values, `supersedes: 2`): reading works, and an edit either changes exactly the status value or refuses and says to edit by hand. It never damages the file.
2. **A title that YAML would misread** (`true`, `123`, `a: b`, `# x`, a leading `*`, quotes, non-ASCII): the written file reads back with the same title.
3. **Two writers at once** (two servers, or a server and `appstein sync`): different numbers, no lost lesson, no half file.
4. **A write that fails halfway** (old file open in an editor on Windows, crash between the two writes of a Replace or a Complete): the reply says what was written and what wasn't, and the next read is still consistent.
5. **A path topic in Windows form** (`lib\ui\home\x.dart`, `.\lib\...`) and a glob that starts with `*`: both match as their POSIX form.

---

### Task 1: Protocol types and tool schemas

**Files:**
- Create: `packages/appstein_protocol/lib/src/decisions/decision_record.dart`
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`, `packages/appstein_protocol/lib/appstein_protocol.dart` (export)
- Test: `packages/appstein_protocol/test/decision_record_test.dart`, `packages/appstein_protocol/test/tool_schemas_test.dart` (extend if it exists, else create)

**Produces:**

```dart
/// §6.7 statuses.
enum DecisionStatus { proposed, accepted, superseded;
  String get jsonName => name;
  static DecisionStatus? tryParse(String text);
}

/// The built-in decision checks (§6.7), in the spec's order.
const decisionChecks = ['stack.provider', 'paths.exist'];

/// One decision record as read from its file.
final class DecisionRecord {
  const DecisionRecord({required this.file, this.number, required this.title,
      required this.status, this.date, this.supersedes,
      this.paths = const [], this.checks = const [], required this.why});
  final String file;        // file name, such as 0002-state.md
  final int? number;        // from the file name; null when it has none
  final String title;       // one line
  final DecisionStatus status; // the status line in the file
  final String? date;
  final int? supersedes;
  final List<String> paths;
  final List<String> checks;
  final String why;         // the body, without a leading "Why:"
  String? get numberText;   // number padded to 4 digits
}
```

`ToolSchemas` additions (all use the existing `jsonObject` / `jsonString` helpers):

- `decisionsInput`: `{topic?: string}`.
- `decisionsResult`: `{mode: 'all'|'words'|'path', topic?, decisions: [decision], superseded: int, withoutPaths?: int, unreadable: [{file, problem}], duplicates: [{number, files: [string]}], problems: [string]}`; required: `mode`, `decisions`, `superseded`, `unreadable`, `duplicates`, `problems`.
- `decision` object: `{number?, title, status, statusInFile?, date?, why, paths, checks, file, supersedes?, supersededBy?, score?}`; required: `title`, `status`, `why`, `paths`, `checks`, `file`. `file` is project-relative (`.appstein/decisions/0002-state.md`); numbers are four-digit strings.
- `recordDecisionInput`: `{title?, why?, status?: 'proposed'|'accepted', paths?: [string], checks?: [string], supersedes?: string, accept?: string}`, nothing required (the two shapes are checked in code).
- `recordDecisionResult`: `{action: 'added'|'replaced'|'accepted', decision, superseded?: decision}`; required: `action`, `decision`.
- `memoryReadResult`: `{current?: string, currentFile: string, currentProblem?: string, lessons: [string], olderLessons: int, lessonsFile: string, lessonsProblem?: string}`; required: `currentFile`, `lessons`, `olderLessons`, `lessonsFile`.
- `memoryWriteInput`: `{kind: 'current'|'lesson'|'complete', text: string}`, both required.
- `memoryWriteResult`: `{kind, file, lesson?: string, added?: bool, cleared?: string}`; required: `kind`, `file`.

- [ ] Tests: each status round-trips its JSON name and `tryParse('nope')` is null; `numberText` pads (`2` → `0002`, `12345` → `12345`); each new schema accepts one hand-written valid value and rejects one with a wrong enum value (through `expectMatchesSchema`'s validator pattern).
- [ ] Run, watch fail, implement, run: `cd packages/appstein_protocol && fvm dart test`.
- [ ] `fvm dart analyze` and `fvm dart format .` clean.

### Task 2: Decision file text (pure)

**Files:**
- Create: `packages/appstein_engine/lib/src/decisions/decision_file.dart`
- Test: `packages/appstein_engine/test/decisions/decision_file_test.dart`

**Produces:**

```dart
sealed class DecisionFile { String get file; int? get number; }
final class ReadDecision extends DecisionFile { final DecisionRecord record; }
final class UnreadableDecision extends DecisionFile { final String problem; }

/// The number a decision file's name starts with (0002-x.md → 2), or null.
int? decisionFileNumber(String file);

/// Reads a decision file's text (§6.7). Never throws.
DecisionFile parseDecisionFile(String file, String text);

/// The text of a new decision file, ending in a line break.
String renderDecision({required int number, required String title,
    required DecisionStatus status, required String date, int? supersedes,
    List<String> paths, List<String> checks, required String why});

/// [text] with its front matter's status value replaced; null when the
/// status line isn't a plain `status: word` line.
String? withDecisionStatus(String text, DecisionStatus status);

/// A file-name slug for [title]: lowercase a-z, 0-9 and hyphens, at most 50
/// characters, `decision` when nothing is left.
String decisionSlug(String title);
```

**Behavior:**
- `parseDecisionFile` keeps today's unreadable reasons word for word (`it has no front matter`, `its front matter has no closing ---`, `its front matter is not valid YAML`, `its front matter is not a map`, `it has no title`, `its status is not accepted, proposed or superseded`), because `INDEX.md` prints them. It drops a BOM, accepts any line break, reads `supersedes` as an integer from `2`, `0002` or `'0002'` (null or `null` → none; anything else → unreadable: `its supersedes is not a decision number`), reads `paths` and `checks` as lists of strings (a single string counts as one item; any other shape → unreadable with `its paths are not a list` / `its checks are not a list`), reads `date` as text, and takes the body after the closing `---`, trimmed, with one leading `Why:` (any case) removed.
- The title is one line, capped at 120 characters as today.
- `renderDecision` writes the keys in the spec's order: `id`, `title`, `status`, `date`, `supersedes`, `paths`, `checks`, then `Why: <why>`. `id` and `supersedes` are four-digit numbers (`supersedes: null` when none). `paths` and `checks` are flow lists (`[]` when empty). A scalar is written plain only when `loadYaml` reads it back as the same string; otherwise it is written as a JSON string (valid YAML double quotes).
- `withDecisionStatus` changes only the value on the first line inside the front matter that matches `status:` + spaces + one bare word, keeping what follows it (a `# comment`) and every other byte, the file's line breaks and BOM included.

- [ ] Tests (table-driven where it fits):
  - the spec's example file reads to the record in §6.7, `why` without the `Why:`;
  - each unreadable reason above, one case each;
  - `supersedes: 2`, `supersedes: 0002`, `supersedes: '0002'`, `supersedes: null`, `supersedes: yes` (unreadable);
  - a `\r\n` file with a BOM reads the same as its `\n` twin;
  - render then parse round-trips for the titles `true`, `123`, `a: b`, `# x`, `*star`, `say "hi"`, `naïve café`, and for the paths `**/x.dart`, `lib/ui/**`;
  - the rendered text of the spec's example equals an expected literal (pins the layout);
  - `withDecisionStatus` on `status: proposed          # proposed | accepted | superseded` keeps the comment; on a `\r\n` file keeps `\r\n`; on `status: "proposed"` and on a file with no status line returns null; a `status:` word in the body below the front matter is left alone;
  - slugs: `State management with provider + ChangeNotifier` → `state-management-with-provider-changenotifier`; a 90-character title is cut to at most 50 without a trailing hyphen; `!!!` and `日本語` → `decision`.
- [ ] Run, watch fail, implement, run: `cd packages/appstein_engine && fvm dart test test/decisions`.

### Task 3: Decisions store (reading) and `INDEX.md` on top of it

**Files:**
- Create: `packages/appstein_engine/lib/src/decisions/decision_store.dart`
- Modify: `packages/appstein_engine/lib/src/index/index_sources.dart` (read through the store; remove `parseDecision` and `decisionNumber`, whose jobs move to Task 2), `packages/appstein_engine/lib/appstein_engine.dart` (exports), `packages/appstein_engine/pubspec.yaml` (`glob: ^2.2.0`)
- Test: `packages/appstein_engine/test/decisions/decision_store_test.dart`; update `test/index/index_sources_test.dart`

**Produces:**

```dart
/// One decision as the readers see it (§6.7 Reading).
final class DecisionEntry {
  final DecisionRecord record;
  final DecisionStatus status;   // effective: superseded when another names it
  final int? supersededBy;       // the active decision that replaces it
  bool get active;               // accepted or proposed, effectively
}

final class DecisionSet {
  final List<DecisionEntry> entries;          // file-name order
  final List<UnreadableDecision> unreadable;  // file-name order
  final Map<int, List<String>> duplicates;    // number → file names
  final String? folderProblem;                // the folder couldn't be listed
  final List<String> problems;                // such as a supersedes cycle
  final Map<String, List<int>> bytes;         // file name → bytes, for hashes
  final Map<String, String> readProblems;     // file name → why unreadable on disk
  int get nextNumber;                          // highest number of any file + 1
  DecisionEntry? numbered(int number);        // null when missing or duplicated
}

/// Reads `.appstein/decisions/` of [projectRoot]. Never throws for the
/// project's own files.
DecisionSet readDecisions(String projectRoot);

/// `.appstein/decisions/<file>` as a project-relative POSIX path.
String decisionPath(String file);
```

**Behavior:**
- Only `*.md` files directly in the folder are read (as today), in file-name order.
- Effective status: an entry is superseded when its own line says so, or when an entry whose own line is `accepted` or `proposed`, and which is not itself superseded by the same rule, names its number in `supersedes`. Resolve from the highest number down; a cycle (A supersedes B, B supersedes A) leaves the higher number active and is reported once in `DecisionSet.problems`.
- `supersededBy` is set when an active decision names the entry, also when its own line already says `superseded`.
- A number used by two or more files is in `duplicates`; `numbered` returns null for it.
- `nextNumber` counts every file with a number prefix, unreadable ones included, so a damaged file's number is never reused.
- `readIndexSources` builds its `IndexDecision` list from the set: active entries and unreadable files, merged in file-name order, with the same `inputs` keys and bytes as today (`decisions/<name>`, `decisions` on a folder error, `unreadable: <reason>` for a file that can't be opened). `INDEX.md` for a project with no implied-superseded decision must not change by one byte.

- [ ] Tests:
  - three files (accepted, proposed, superseded line) → two active, one superseded;
  - `0003` names `supersedes: 0001` while `0001` still says `accepted` → `0001` is superseded with `supersededBy: 3`;
  - a superseded `0003` naming `0001` does not supersede it;
  - a cycle keeps the higher number and reports one problem;
  - two files numbered 5 → `duplicates[5]` has both, `numbered(5)` is null, `nextNumber` is 6;
  - an unreadable `0009-x.md` → `nextNumber` is 10;
  - no folder → empty set, `nextNumber` 1, no problem;
  - a folder that is a file → `folderProblem` set;
  - `index_sources_test`: existing cases still pass through the new path; new case: the implied-superseded `0001` is left out of `IndexSources.decisions`.
- [ ] Run the engine suite: `cd packages/appstein_engine && fvm dart test`. The `INDEX.md` goldens must pass unchanged.

### Task 4: The `decisions` query (pure)

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/decisions_query.dart`
- Test: `packages/appstein_engine/test/mcp/decisions_query_test.dart`

**Produces:** `ToolAnswer decisionsInfo(DecisionSet decisions, {String? topic})`, returning a `ToolReply` that matches `ToolSchemas.decisionsResult`.

**Behavior:**
- A folder problem is a `ToolRefusal` naming it.
- **No topic** (null or blank): `mode: all`, every active entry in file-name order, `superseded` = how many aren't active.
- **Path topic:** the topic has no white space and contains `/` or `\`, or ends in a file extension. It is made POSIX (`\` → `/`, a leading `./` dropped). `mode: path`, the active entries with a `paths` pattern that matches it (`Glob(pattern, context: p.posix)`), in file-name order; `withoutPaths` counts the active entries with no paths. A pattern that isn't a valid glob never matches and is named in `problems`.
- **Word topic:** `mode: words`. Words are the topic's lowercase runs of letters and digits. Per word, the best of: the decision's number (`2` or `0002`) 5, in the title 3, in a path 2, in the reason 1 (plain substring, case ignored). A decision's score is the sum; zero is left out. Order: score down, active before superseded, then number down. Superseded entries are included with `supersededBy`.
- Every reply lists `unreadable`, `duplicates` and `problems`.
- `statusInFile` appears only when it differs from `status`.
- Summary sentences, one each: `3 decisions are in force (2 accepted, 1 proposed); 1 is superseded.` / `2 decisions cover lib/ui/home/x.dart; 1 more has no paths and applies everywhere: call decisions() without a topic.` / `No decision covers …` / `2 decisions match "state management".` / `No decision matches "…".` Add `1 file is unreadable.` and `Number 0005 is used twice; rename one file.` when they apply.

- [ ] Tests: one per bullet above; the path forms `lib\ui\home\x.dart` and `./lib/ui/home/x.dart`; a pattern `**/view_models/**`; a topic `0002` finds decision 2 first; each summary string; every reply matches `ToolSchemas.decisionsResult` (`expectMatchesSchema`) and has no nulls.
- [ ] Run, watch fail, implement, run.

### Task 5: Recording decisions (write)

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/record_decision.dart`
- Modify: `packages/appstein_engine/lib/src/decisions/decision_store.dart` (the write half)
- Test: `packages/appstein_engine/test/decisions/decision_write_test.dart`, `packages/appstein_engine/test/mcp/record_decision_test.dart`

**Produces:**

```dart
/// What record_decision was asked to do, already checked for shape.
sealed class DecisionRequest {}
final class AddDecision extends DecisionRequest { title, why, status, paths, checks, supersedes (int?) }
final class AcceptDecision extends DecisionRequest { number }

/// Thrown for a request the project's decisions don't allow; [message] is
/// for the agent.
final class DecisionRefused implements Exception { final String message; }

/// Carries out [request] under the write lock. Returns the files it wrote.
Future<DecisionWritten> writeDecision(String projectRoot, DecisionRequest request,
    {required String today, Duration lockTimeout});

final class DecisionWritten {
  final String action;           // added | replaced | accepted
  final DecisionEntry decision;  // re-read from disk after the write
  final DecisionEntry? superseded;
  final String? warning;         // a second write that failed
}

/// The record_decision tool: checks [arguments], then writes.
Future<ToolAnswer> recordDecision(String projectRoot, Map<String, Object?> arguments,
    {required String today});
```

**Behavior of `recordDecision` (argument checks, each a `ToolRefusal`, nothing written):**
- `accept` together with any other argument: `Pass \`accept\` alone, or the fields of a new decision.`
- neither `accept` nor `title`: say what the two shapes are;
- title blank, or longer than 120 characters after white space is collapsed;
- why blank;
- a check not in `decisionChecks`, naming the valid ones;
- a path that is empty, absolute (`/x`, `C:\x`, `C:/x`), has a `..` segment, or isn't a valid glob; `\` is turned into `/` first;
- `accept` or `supersedes` that isn't a number (`2`, `0002`).

**Behavior of `writeDecision` (inside `KnowledgeLock.acquire('<root>/.appstein')`, reading the set after the lock is held):**
- **Add:** number = `nextNumber`; file `NNNN-<slug>.md`; written with `replaceFile`.
- **Replace:** the target must be found by `numbered` (else `DecisionRefused`: missing, or `Number 0005 is used by two files (a, b); rename one first.`), and active (else: already superseded, by which decision when known). Write the new file first, then the old file with `withDecisionStatus(…, superseded)`. When that returns null, or the second write throws, the new file stays and `warning` says the old file's status line couldn't be changed and why; the old one still counts as superseded by the reading rule.
- **Accept:** the target must be found, and effectively `proposed` (else say its status). `withDecisionStatus` null → `DecisionRefused`: `Its status line isn't a plain \`status: proposed\`; edit the file by hand.`
- A `KnowledgeLockTimeout` or `KnowledgeWriteException` becomes a `ToolRefusal` with its text.
- The reply's `decision` (and `superseded`) come from reading the folder again after the write.
- Summaries: `Recorded decision 0004 as proposed in .appstein/decisions/0004-….md. It becomes binding when the user agrees: call record_decision with accept: "0004".` / `Recorded decision 0004 as accepted in ….` / `Recorded decision 0005, which replaces 0002.` / `Decision 0003 is now accepted.`

- [ ] Tests (temp project folders, a fixed `today`):
  - first add in an empty project creates the folder and `0001-<slug>.md`, status proposed, date today, and the file equals an expected literal;
  - add with `status: accepted`, paths and checks;
  - the next add is `0002`; after an unreadable `0007-x.md`, the next is `0008`;
  - replace: new file names `supersedes`, old file's status line alone changed (compare every other line), reply has both;
  - replace of a missing, a duplicated, and an already superseded number: refused, folder unchanged (compare a listing with bytes);
  - replace when the old file's status line is quoted: new file written, warning set, a fresh read shows the old one superseded;
  - accept: line changed, comment kept, `\r\n` kept; accept of an accepted, a superseded, an implied-superseded and a missing number: refused, nothing changed;
  - every argument refusal above, one case each, with nothing written;
  - two `writeDecision` adds started together get different numbers (same isolate, through the lock's queue);
  - while another process holds the lock (`test/knowledge/support/hold_lock.dart`) a write with a short timeout is refused with the lock's message and writes nothing.
- [ ] Run, watch fail, implement, run.

### Task 6: Memory store and tools

**Files:**
- Create: `packages/appstein_engine/lib/src/memory/memory_store.dart`, `packages/appstein_engine/lib/src/mcp/memory_tools.dart`
- Test: `packages/appstein_engine/test/memory/memory_store_test.dart`, `packages/appstein_engine/test/mcp/memory_tools_test.dart`

**Produces:**

```dart
const memoryCurrentPath = '.appstein/memory/current.md';
const memoryLessonsPath = '.appstein/memory/lessons.md';

/// `- <date>: <text on one line>`.
String lessonLine(String date, String text);

/// The lessons in a lessons.md text: its non-blank lines that aren't
/// headings, without the list marker.
List<String> lessonsIn(String text);

/// [bytes] of lessons.md with [line] appended, keeping every existing byte;
/// null when the file already holds that lesson (same text, any date).
List<int>? withLesson(List<int>? bytes, String line);

/// memory_read's answer. Never refuses: a file that can't be read is named
/// in currentProblem / lessonsProblem.
ToolAnswer memoryRead(String projectRoot, {int newest = 50});

/// memory_write's answer; writes under the write lock.
Future<ToolAnswer> memoryWrite(String projectRoot, Map<String, Object?> arguments,
    {required String today});
```

**Behavior:**
- `current`: text must not be blank; the file becomes the text with exactly one line break at its end.
- `lesson`: text must not be blank; white space runs (line breaks included) become one space. `withLesson` adds a line break before the new line when the file doesn't end with one, and uses `\r\n` when the file already does. A lesson already there → nothing written, `added: false`, summary says it was already recorded.
- `complete`: text must not be blank (`Give a one-paragraph summary of the task as \`text\`.`); `current.md` must exist and not be blank (`No task is in progress, so there is nothing to finish. Use kind: lesson to record a lesson.`). The lesson is appended first, then `current.md` is deleted. If the delete fails, the reply is a refusal that says the lesson was recorded and why the file couldn't be deleted. Running it again after such a failure deletes the file and adds nothing twice.
- `memoryRead`: `current` is the whole text without a BOM (left out when the file is missing or blank); `lessons` are the newest `newest` in file order; `olderLessons` counts the rest. Summary: `A task is in progress (12 lines); 3 lessons recorded.` / `No task is in progress; no lessons recorded yet.` / with `47 older lessons are in .appstein/memory/lessons.md.` when cut.

- [ ] Tests:
  - `lessonLine('2026-10-06', 'a\n  b')` is `- 2026-10-06: a b`;
  - `lessonsIn` skips blank lines and `# Lessons`, strips `- `, keeps a line a human wrote without a marker;
  - `withLesson`: null bytes → one line + `\n`; a file without a final line break gets one; a `\r\n` file gets `\r\n`; a BOM and every earlier byte are kept (compare prefixes); the same text with another date → null;
  - write `current` twice → the second text replaces the first;
  - `complete` happy path: lesson appended, `current.md` gone, reply names both files;
  - `complete` with no current, with a blank current, with a blank text: refused, files unchanged;
  - `complete` again after the lesson was already appended (simulate the half-done state): file deleted, lessons unchanged;
  - `memoryRead` on an empty project, with 60 lessons (50 returned, 10 older), with a `lessons.md` that is a folder (`lessonsProblem` set, no throw);
  - each reply matches its schema and has no nulls;
  - two `lesson` writes started together both land.
- [ ] Run, watch fail, implement, run.

### Task 7: The server serves the four tools, and `INDEX.md` names them

**Files:**
- Modify: `packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart`, `packages/appstein_engine/lib/src/mcp/tool_names.dart`, `packages/appstein_engine/lib/src/index/index_document.dart`, `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/mcp/appstein_mcp_server_test.dart`, `packages/appstein_engine/test/mcp/mcp_stdio_test.dart`, `packages/appstein_engine/test/index/index_document_test.dart`, plus any CLI test that counts tools (`packages/appstein_cli/test/`)

**Behavior:**
- `mcpToolNames` gains, after `toolchain`: `decisions`, `record_decision`, `memory_read`, `memory_write`. Its comment loses the "come with slice 1c.2" sentence.
- `AppsteinMcpServer` takes an optional `DateTime Function()? clock` (default `DateTime.now`); `today` is its local date as `yyyy-MM-dd`.
- Read tools: `decisions` → `decisionsInfo(readDecisions(projectRoot), topic: …)`; `memory_read` → `memoryRead(projectRoot)`. Neither needs a generated knowledge file, so neither calls `refusalFor`.
- A new private `_writeTool` registers a tool whose handler, inside `_oneAtATime`: runs `_freshen()`, runs the write, and when the write gave a `ToolReply`, runs `_freshen()` again and reports that second freshness (it names the decision or memory file as what changed, and `INDEX.md` is current when the reply arrives). A refusal reports the first freshness. A throw is caught as today.
- Tool descriptions (the agent reads these):
  - `decisions`: `The project's recorded decisions (architecture, state management, conventions) with the reason for each. Without a topic: every decision in force. With words, such as "state management": the decisions that mention them. With a file path, such as \`lib/ui/home/home_screen.dart\`: the decisions that cover that file. Check it before a change that a decision may already settle.`
  - `record_decision`: `Record a choice that binds later work, with its reason. Pass title and why (and paths, the globs it applies to); it is saved as proposed. Pass status: accepted only when the user agreed to this decision in this conversation. To replace an older decision, add supersedes with its number. To accept a proposed decision once the user agrees, pass only accept with its number. An existing decision's text is never rewritten. The file is committed: never put secrets in it.`
  - `memory_read`: `The task in progress (goal, plan, status, open questions) and the lessons recorded so far. Read it when you start or resume work.`
  - `memory_write`: `Keep the project's memory. kind: current replaces the task in progress with text (goal, plan, status, open questions). kind: lesson appends one dated line to the lessons. kind: complete finishes the task: text is your one-paragraph summary, which is saved as a lesson, and the task in progress is cleared. The files are committed: never put secrets in them.`
- The server's `instructions` gain one sentence: `Read \`memory_read\` when you resume work, and record a choice that binds later work with \`record_decision\`.`
- `indexTools` gains `record_decision` and `memory_write`. `_rules` gains, after the toolchain rule and only when both tools are offered: ``- Record a choice that binds later work with `record_decision()`, and keep the task in progress with `memory_write()`.``

- [ ] Tests (in-process client, the fixture app, a fixed clock):
  - the tool list is `mcpToolNames`, eleven names, each with a description and an output schema (rename the "seven tools" test);
  - the four new tools are added to the "every tool answers and matches its output schema" table, with `record_decision` and `memory_write` given valid arguments;
  - `record_decision` then `overview`: the index lists the new decision, and the second call's freshness is `current` (the write already refreshed it);
  - the `record_decision` reply's freshness is `rebuilt` and its `changed` names the decision file;
  - `memory_write` current then `overview`: "Current work" shows the text; `complete` then `overview`: "None recorded yet.";
  - a refused write is an error result whose text states the freshness, and no file changed;
  - `decisions` with a path topic through the server;
  - `index_document_test`: the rule line appears with the default tools and is absent when either tool is missing; the very-large-project budget test still passes; update goldens that hold the rules (expected: one added line);
  - `mcp_stdio_test`: the real process answers `record_decision`, the file exists on disk, and `decisions` returns it.
- [ ] Run all four suites and the repo root: `cd packages/appstein_protocol && fvm dart test`, `cd packages/appstein_engine && fvm dart test`, `cd packages/appstein_cli && fvm dart test`, `cd packages/appstein_lints && fvm dart test`, and `fvm dart test` at the root. `fvm dart analyze` and `fvm dart format --output=none --set-exit-if-changed .` clean.
- [ ] Run the product on a scratch copy of the fixture app outside the repo: compile the CLI, `appstein sync`, then drive `appstein mcp` by hand (record, accept, replace, memory current/lesson/complete) and read every file it wrote and the resulting `INDEX.md`.

### Task 8: Docs, progress and graph

**Files:**
- Create: `docs/guide/decisions-and-memory.md` (covers the new `decisions/`, `memory/` and the three new `mcp/` files)
- Modify: `docs/guide/mcp-server.md` (the four tools, write tools and the second freshness check), `docs/guide/index-md.md` (the rule line, decisions read through the store), any page whose `covers` lists a changed file
- Modify: `docs/superpowers/progress.yaml`, this plan (Notes from execution)

- [ ] Write the guide page: what the two layers are, the file formats with one example each, the reading rules, the three write actions, what is refused, how a write stays safe (lock, one-step replace, the order of the two writes), and how to test by hand.
- [ ] `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`; read back the rendered progress section.
- [ ] One fresh review of the whole branch on the most capable model, with this plan's Review Focus; one fix pass, each fix test-first.
- [ ] Notes from execution in this plan; `progress.yaml`: 1c.2 done with its PR and date, 1c.3 next (in the same commit, once the PR is open).
- [ ] `/graphify . --update` until `tool/check_graph.py` reports nothing.
- [ ] With the owner's OK: a short Claude Code run on the fixture app that asks the agent to record a decision and finish a task, to see that it calls the tools from their descriptions alone.

## Carried to later slices

- **1d:** run `checks` (`stack.provider`, `paths.exist`, `decision.drift`); the `lessons.md` 200-line finding; `knowledge.stale`.
- **1c.3:** `docs/app/decisions.md` reads through `readDecisions`.
- **1e / 1f:** the `appstein-develop` skill teaches when to record a decision and how to keep memory; a CLI way to accept a decision if hand-editing proves awkward.
- **Not decided:** a size limit on a `decisions` reply for projects with very many long decisions.
