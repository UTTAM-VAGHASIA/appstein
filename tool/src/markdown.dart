/// What a line of Markdown is, as [FenceTracker] sees it.
enum FenceLine {
  /// A line outside code fences.
  prose,

  /// The triple-backtick line that opens a code fence.
  open,

  /// The triple-backtick line that closes a code fence.
  close,

  /// A line inside a code fence.
  code,
}

/// Tracks triple-backtick code fences through a Markdown file, one line at a
/// time. The guide tools read only prose lines: links, paths, markers and
/// covers comments inside a fence are examples.
final class FenceTracker {
  var _inFence = false;

  /// Reads the next [line] of the file and says what it is.
  FenceLine next(String line) {
    if (line.trimLeft().startsWith('```')) {
      _inFence = !_inFence;
      return _inFence ? FenceLine.open : FenceLine.close;
    }
    return _inFence ? FenceLine.code : FenceLine.prose;
  }
}

final _link = RegExp(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)');

/// The Markdown links in [line] that point at a file in the repo; web and
/// mail links and in-page `#` anchors are left out. `target` is the link as
/// written; `path` is its file part, without the `#` anchor and with `%`
/// escapes decoded.
Iterable<({String target, String path})> fileLinks(String line) sync* {
  for (final match in _link.allMatches(line)) {
    final target = match.group(1)!;
    if (target.startsWith('http://') ||
        target.startsWith('https://') ||
        target.startsWith('mailto:') ||
        target.startsWith('#')) {
      continue;
    }
    yield (target: target, path: Uri.decodeFull(target.split('#').first));
  }
}
