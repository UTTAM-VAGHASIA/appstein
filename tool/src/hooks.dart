import 'dart:io';

import 'package:path/path.dart' as p;

/// Marks the start of the block Appstein keeps in a git hook file.
const hookBlockStart = '# appstein-hook-start';

/// Marks the end of that block.
const hookBlockEnd = '# appstein-hook-end';

/// The blocks Appstein keeps in the repo's git hooks, by hook name
/// (spec §19.6).
///
/// Git runs hooks with its own `sh`, on Windows too. Each block runs in a
/// subshell, so its `exit` never stops the other blocks in the same file,
/// such as graphify's.
const hookBlocks = {
  'post-commit': _postCommit,
  'post-merge': _postMerge,
  'post-rewrite': _postRewrite,
};

const _postCommit = r'''
# appstein-hook-start
# Warns when the developer guide may have fallen behind this commit
# (spec §19.6). CI is the gate; this only warns. Skip it once with
# APPSTEIN_SKIP_DOCS_HOOK=1. Installed by: fvm dart run tool/install_hooks.dart
(
  [ "${APPSTEIN_SKIP_DOCS_HOOK:-0}" = "1" ] && exit 0
  GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
  [ -d "$GIT_DIR/rebase-merge" ] && exit 0
  [ -d "$GIT_DIR/rebase-apply" ] && exit 0
  [ -f tool/check_guide.dart ] || exit 0
  git rev-parse -q --verify HEAD~1 >/dev/null || exit 0
  if command -v fvm >/dev/null 2>&1; then
    fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only
  elif command -v dart >/dev/null 2>&1; then
    dart run tool/check_guide.dart --since HEAD~1 --warn-only
  fi
  exit 0
)
# appstein-hook-end''';

const _postMerge = r'''
# appstein-hook-start
# Rebuilds the graphify graph after a merge or pull, which graphify's own
# hooks miss. It reuses graphify's post-checkout rebuild, as if HEAD had
# switched branches. Installed by: fvm dart run tool/install_hooks.dart
(
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)
# appstein-hook-end''';

const _postRewrite = r'''
# appstein-hook-start
# Rebuilds the graphify graph after a rebase; graphify's post-commit hook
# already covers an amend. It reuses graphify's post-checkout rebuild.
# Installed by: fvm dart run tool/install_hooks.dart
(
  [ "$1" = "rebase" ] || exit 0
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)
# appstein-hook-end''';

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
