/// The limit for a fast `verify` that an agent meets (design §15): the
/// warm `verify` tool of a running `appstein mcp`, after one file is edited.
const warmLimit = Duration(seconds: 5);

/// The middle of [times], an odd number of them.
Duration medianOf(List<Duration> times) =>
    (times.toList()..sort())[times.length ~/ 2];

/// Why the [median] of the warm fast runs fails the limit, or null when it
/// is under it. The design says "< 5 s" (§15), so a median of exactly 5 s
/// fails. The message gives the measured time.
String? warmLimitMiss(Duration median) => median < warmLimit
    ? null
    : 'The warm fast verify took ${median.inMilliseconds} ms, the median of '
          'three, and the limit is under ${warmLimit.inSeconds} s (design '
          '§15). The limit is not changed to fit.';

/// [original] (the text of a Dart file) with a real error added at the end,
/// the [n]th edit of a measurement, and the line the analyzer reports it on.
///
/// Every edit has a size and a line of its own: the error is `int wrongN()`
/// returning a string of `n + 1` letters, after `n` blank lines. A file
/// system with a coarse clock can't hide an edit that changes the size, and
/// a reply that is left from an earlier edit names the wrong line.
({String text, int line}) editWithError(String original, int n) {
  final text =
      "$original\n${'\n' * n}/// Wrong, edit $n.\n"
      "int wrong$n() => '${'x' * (n + 1)}';\n";
  return (
    text: text,
    line: text.substring(0, text.indexOf('int wrong$n')).split('\n').length,
  );
}

/// The findings of a `verify` `tools/call` [reply], or null with the reason
/// in [problem] when the reply is not a normal answer.
({List<Map<String, Object?>>? findings, String? problem}) _findingsOf(
  Map<String, Object?> reply,
) {
  if (reply['isError'] == true) {
    final text = [
      for (final part in (reply['content'] as List?) ?? const [])
        if (part is Map && part['text'] is String) part['text'],
    ].join(' ');
    return (findings: null, problem: 'the tool answered with an error: $text');
  }
  final structured = reply['structuredContent'];
  final findings = structured is Map ? structured['findings'] : null;
  if (findings is! List) {
    return (findings: null, problem: 'the reply has no findings list: $reply');
  }
  return (findings: findings.cast<Map<String, Object?>>(), problem: null);
}

/// Why [reply] does not report the error that was written to [file] at
/// [line] (a `dart.error` finding there), or null when it does. A fast
/// answer that missed the change must fail the measurement, however fast it
/// was.
String? missedError(
  Map<String, Object?> reply, {
  required String file,
  required int line,
}) {
  final (:findings, :problem) = _findingsOf(reply);
  if (findings == null) return problem;
  final reported = findings.any(
    (finding) =>
        finding['id'] == 'dart.error' &&
        finding['file'] == file &&
        finding['line'] == line,
  );
  if (reported) return null;
  final seen = [
    for (final finding in findings)
      '${finding['id']} ${finding['file']}:'
          '${finding['line']}',
  ];
  return 'the reply does not report a dart.error at $file:$line; its '
      'findings are ${seen.isEmpty ? 'none' : seen.join(', ')}';
}

/// Why [reply] is not the answer for a project where [file] (or, with no
/// file, any file) has no error, or null when it is. A `dart.error` that is
/// still there after the error was fixed means the answer is old.
String? unexpectedError(Map<String, Object?> reply, {String? file}) {
  final (:findings, :problem) = _findingsOf(reply);
  if (findings == null) return problem;
  final left = [
    for (final finding in findings)
      if (finding['id'] == 'dart.error' &&
          (file == null || finding['file'] == file))
        '${finding['file']}:${finding['line']}',
  ];
  return left.isEmpty
      ? null
      : 'the reply still reports an error at ${left.join(', ')}';
}
