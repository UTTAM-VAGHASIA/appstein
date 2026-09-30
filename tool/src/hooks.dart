import 'dart:io';

import 'package:path/path.dart' as p;

/// Marks the start of the block Appstein keeps in a git hook file.
const hookBlockStart = '# appstein-hook-start';

/// Marks the end of that block.
const hookBlockEnd = '# appstein-hook-end';

/// The blocks Appstein keeps in the repo's git hooks, by hook name
/// (spec §19.6).
///
/// Git runs hooks with its own `sh`, on Windows too. Each part of a block
/// runs in a subshell, so its `exit` never stops the next part, or another
/// block in the same file, such as graphify's.
final hookBlocks = {
  'post-checkout': _block([_graphRepair]),
  'post-commit': _block([_docsCheck, _graphCheck(_notWhileRebasing)]),
  'post-merge': _block([_mergeRebuild, _graphCheck('', repairing: true)]),
  'post-rewrite': _block([
    _rebaseRebuild,
    _graphCheck(_onlyAfterRebase, repairing: true),
  ]),
};

String _block(List<String> parts) =>
    '$hookBlockStart\n${parts.join('\n')}\n'
    '# Installed by: fvm dart run tool/install_hooks.dart\n$hookBlockEnd';

const _notWhileRebasing = r'''
  GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
  [ -d "$GIT_DIR/rebase-merge" ] && exit 0
  [ -d "$GIT_DIR/rebase-apply" ] && exit 0
''';

const _onlyAfterRebase = r'''
  [ "$1" = "rebase" ] || exit 0
''';

const _docsCheck =
    r'''
# Warns when the developer guide may have fallen behind this commit
# (spec §19.6). CI is the gate; this only warns. Skip it once with
# APPSTEIN_SKIP_DOCS_HOOK=1.
(
  [ "${APPSTEIN_SKIP_DOCS_HOOK:-0}" = "1" ] && exit 0
''' +
    _notWhileRebasing +
    r'''
  [ -f tool/check_guide.dart ] || exit 0
  git rev-parse -q --verify HEAD~1 >/dev/null || exit 0
  if command -v fvm >/dev/null 2>&1; then
    fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only
  elif command -v dart >/dev/null 2>&1; then
    dart run tool/check_guide.dart --since HEAD~1 --warn-only
  fi
  exit 0
)''';

const _mergeRebuild = r'''
# Rebuilds the graphify graph after a merge or pull, which graphify's own
# hooks miss. It replays the post-checkout hook (graphify's rebuild and the
# graph repair), as if HEAD had switched branches.
(
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  APPSTEIN_HOOK_REPLAY=1 "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

const _rebaseRebuild = r'''
# Rebuilds the graphify graph after a rebase; graphify's post-commit hook
# already covers an amend. It replays the post-checkout hook.
(
  [ "$1" = "rebase" ] || exit 0
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  APPSTEIN_HOOK_REPLAY=1 "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

/// Finds graphify's Python for a graph part of a block: sets `py`, or runs
/// [otherwise] (`sh` lines that end with `exit 0`) when
/// `graphify-out/.graphify_python` is missing or names no executable.
String _graphifyPython(String otherwise) =>
    r'''
  [ -f tool/check_graph.py ] && [ -f graphify-out/graph.json ] || exit 0
  py=""
  [ -f graphify-out/.graphify_python ] &&
    py=$(tr -d '\r\n' < graphify-out/.graphify_python)
  if [ -z "$py" ] || [ ! -x "$py" ]; then
''' +
    otherwise +
    r'''
  fi
''';

/// Starts the graph repair in the background after a branch switch, and
/// when a merge or rebase replays this hook (spec §19.6). It waits for
/// graphify's own rebuild, then puts back the docs that rebuild dropped.
final _graphRepair =
    r'''
# Puts back, from graphify's cache, the docs a code rebuild dropped from the
# knowledge graph (spec §19.6). It runs in the background, after graphify's
# rebuild, and writes to graphify's log. Skip it with
# APPSTEIN_SKIP_GRAPH_HOOK=1; it also stays off with GRAPHIFY_SKIP_HOOK=1.
(
  [ "${APPSTEIN_SKIP_GRAPH_HOOK:-0}" = "1" ] && exit 0
  [ "${GRAPHIFY_SKIP_HOOK:-0}" = "1" ] && exit 0
  [ "$3" = "1" ] && [ "$1" != "$2" ] || exit 0
  if [ "${APPSTEIN_HOOK_REPLAY:-0}" != "1" ]; then
    # A rebase checks out commits on its way; post-rewrite replays this
    # hook once it is done.
    GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
    [ -d "$GIT_DIR/rebase-merge" ] && exit 0
    [ -d "$GIT_DIR/rebase-apply" ] && exit 0
  fi
''' +
    _graphifyPython('    exit 0\n') +
    r'''
  # A branch from before the repair has a check_graph.py without it.
  grep -q -e --detach tool/check_graph.py || exit 0
  "$py" tool/check_graph.py --detach
  exit 0
)''';

/// Warns when the knowledge graph doesn't hold the current docs
/// (spec §19.6), by running `tool/check_graph.py` with graphify's Python.
/// [guard] is `sh` lines that end the check early when this hook shouldn't
/// run it. With [repairing], the hook has just replayed post-checkout, which
/// started the graph repair, so docs missing from the graph are reported as
/// being repaired, unless `GRAPHIFY_SKIP_HOOK=1` kept the repair off.
String _graphCheck(String guard, {bool repairing = false}) =>
    r'''
# Warns when the knowledge graph doesn't hold the current docs (spec §19.6).
# It only warns. Skip it with APPSTEIN_SKIP_GRAPH_HOOK=1.
(
  [ "${APPSTEIN_SKIP_GRAPH_HOOK:-0}" = "1" ] && exit 0
''' +
    guard +
    _graphifyPython(r'''
    echo "graphify: the graph check could not run: graphify-out/.graphify_python doesn't name graphify's Python. Run /graphify . --update to set it."
    exit 0
''') +
    (repairing
        ? r'''
  # A branch from before --skip-repairable has a check_graph.py without it.
  if [ "${GRAPHIFY_SKIP_HOOK:-0}" = "1" ] ||
      ! grep -q -e --skip-repairable tool/check_graph.py; then
    "$py" tool/check_graph.py --quiet
  else
    "$py" tool/check_graph.py --quiet --skip-repairable
  fi
  exit 0
)'''
        : r'''
  "$py" tool/check_graph.py --quiet
  exit 0
)''');

/// Where Appstein's block is in [text], or null when it has none. Throws
/// [FormatException] when a start marker has no end marker.
(int, int)? _blockRange(String text) {
  final start = text.indexOf(hookBlockStart);
  if (start < 0) return null;
  final end = text.indexOf(hookBlockEnd, start);
  if (end < 0) {
    throw const FormatException(
      'The hook has "$hookBlockStart" but no "$hookBlockEnd". Fix or delete '
      'the file, then run the installer again.',
    );
  }
  return (start, end + hookBlockEnd.length);
}

/// [existing] (a hook file's text, or null when there is no file) with
/// [block] in it. An older Appstein block is replaced in place; otherwise
/// [block] is appended. Everything else, such as graphify's block, is kept.
String upsertHookBlock(String? existing, String block) {
  if (existing == null || existing.trim().isEmpty) {
    return '#!/bin/sh\n$block\n';
  }
  final text = existing.replaceAll('\r\n', '\n');
  final range = _blockRange(text);
  if (range == null) {
    return '${text.endsWith('\n') ? text : '$text\n'}\n$block\n';
  }
  return text.replaceRange(range.$1, range.$2, block);
}

/// [existing] without Appstein's block, or [existing] unchanged when it has
/// none. Null when nothing but the `#!` line would be left, meaning the file
/// can be deleted.
String? removeHookBlock(String existing) {
  final text = existing.replaceAll('\r\n', '\n');
  final range = _blockRange(text);
  if (range == null) return existing;
  final before = text.substring(0, range.$1).trimRight();
  final after = text.substring(range.$2).trim();
  final rest = [
    if (before.isNotEmpty) before,
    if (after.isNotEmpty) after,
  ].join('\n\n');
  if (rest.isEmpty || rest == '#!/bin/sh') return null;
  return '$rest\n';
}

/// Writes Appstein's block into each hook in [hooksDir], or with [remove]
/// takes it out. Returns one line per hook saying what changed. A file left
/// with nothing but `#!/bin/sh` is deleted. On macOS and Linux, hooks are
/// made executable.
List<String> installHookBlocks(String hooksDir, {bool remove = false}) {
  Directory(hooksDir).createSync(recursive: true);
  final report = <String>[];
  for (final entry in hookBlocks.entries) {
    final file = File(p.join(hooksDir, entry.key));
    final before = file.existsSync() ? file.readAsStringSync() : null;
    if (remove) {
      final after = before == null ? before : removeHookBlock(before);
      if (before == null || after == before) {
        report.add('${entry.key}: not installed');
      } else if (after == null) {
        file.deleteSync();
        report.add('${entry.key}: removed (file deleted)');
      } else {
        file.writeAsStringSync(after);
        report.add('${entry.key}: removed');
      }
      continue;
    }
    final after = upsertHookBlock(before, entry.value);
    if (after == before) {
      report.add('${entry.key}: up to date');
    } else {
      file.writeAsStringSync(after);
      report.add('${entry.key}: ${before == null ? 'installed' : 'updated'}');
    }
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
  }
  return report;
}
