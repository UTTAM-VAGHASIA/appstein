import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// One `// appstein:ignore <check-id> — <reason>` or
/// `// appstein:ignore-file <check-id> — <reason>` comment in a Dart file
/// (spec §9.7).
///
/// It is what the comment says and where it is, not whether it works: whether
/// it has a reason, names a check of the project, or hides anything is judged
/// when the suppressions are applied (`applySuppressions`).
final class SuppressionComment {
  /// Creates one.
  const SuppressionComment({
    required this.file,
    required this.line,
    required this.forFile,
    required this.id,
    this.reason,
    this.firstLine,
    this.lastLine,
    this.afterDeclaration = false,
  });

  /// The file it is in, from the project root, with `/` on every system.
  final String file;

  /// The 1-based line the comment is on.
  final int line;

  /// Whether it is an `appstein:ignore-file` comment, which is about the
  /// whole file. An `appstein:ignore` comment is about a line.
  final bool forFile;

  /// The text between the comment's keyword and the separator, trimmed: the
  /// check ID it names. It is empty when there is none, and it is not an ID
  /// when the comment names several (`dart.error, dart.lint`), which no check
  /// has.
  final String id;

  /// What follows the separator, trimmed; null when the comment has no
  /// separator or nothing after it.
  final String? reason;

  /// For an `appstein:ignore` comment: the first and last line it hides the
  /// findings of. A comment that ends a line of code hides that one line.
  /// One alone on its line hides everything up to the next line of code, the
  /// comments between included, so it also reaches an `// ignore:` comment
  /// written between it and the code. Both are null for an
  /// `appstein:ignore-file` comment, and for a comment alone on its line with
  /// no line of code after it.
  final int? firstLine;

  /// See [firstLine].
  final int? lastLine;

  /// Whether an `appstein:ignore-file` comment is after the file's first
  /// declaration, where it hides nothing. False for any other comment.
  final bool afterDeclaration;

  /// Whether the comment, as written, would hide [finding] if its check were
  /// [finding]'s: the finding is in this file and, for a line comment, on a
  /// line the comment covers. It does not look at [id], at the reason, or at
  /// [afterDeclaration] on its own account.
  bool covers(Finding finding) {
    if (finding.file != file) return false;
    if (forFile) return !afterDeclaration;
    final line = finding.line;
    final first = firstLine;
    final last = lastLine;
    if (line == null || first == null || last == null) return false;
    return line >= first && line <= last;
  }
}

/// The comment's keyword, and what follows it. `///` and `////` are not
/// suppressions: the pattern needs a `//` that is not followed by a third
/// slash. The keyword ends at a space or the end of the line, so
/// `appstein:ignored` and `appstein:ignore-files` are not it.
final _comment = RegExp(r'^//(?!/)\s*appstein:ignore(-file)?(?=\s|$)(.*)$');

/// What separates the ID from the reason: `—`, `--` or a hyphen with a space
/// on each side. The first one in the text ends the ID, so an ID with a
/// hyphen (`my-pack.some-check`) is read whole.
final _separator = RegExp(r'\s*(?:—|--)\s*|\s+-\s+');

/// The `// appstein:ignore` and `// appstein:ignore-file` comments in the
/// Dart source [content], in line order, each as a comment of [file].
///
/// Only a real line comment counts, so the same text inside a string, a
/// block comment or a doc comment never does (the source is parsed with the
/// pinned `analyzer` package, as `readDeprecationIgnores` does). [content]
/// need not be valid Dart. [parse], when given, supplies the parsed source,
/// so a caller that parses it for another purpose parses it once; it is not
/// called when [content] has no `appstein:ignore` at all.
List<SuppressionComment> suppressionCommentsIn(
  String content, {
  required String file,
  CompilationUnit Function()? parse,
}) {
  // Most files have none: they are not parsed at all.
  if (!content.contains('appstein:ignore')) return const [];
  final unit =
      parse?.call() ??
      parseString(content: content, throwIfDiagnostics: false).unit;
  final lineInfo = unit.lineInfo;
  int lineOf(int offset) => lineInfo.getLocation(offset).lineNumber;
  // The line a token ends on: a multi-line string ends below where it starts.
  int endLine(Token token) =>
      lineOf(token.end > token.offset ? token.end - 1 : token.offset);
  // The lines that hold code: a token's first to last line, so every line
  // of a multi-line string counts.
  final codeLines = <int>{};
  // The comments, each with whether code stands before it on its line.
  final found = <({Token token, bool trailing})>[];
  Token? previous;
  for (var token = unit.beginToken; ; token = token.next!) {
    for (
      Token? comment = token.precedingComments;
      comment != null;
      comment = comment.next
    ) {
      if (_comment.hasMatch(comment.lexeme)) {
        found.add((
          token: comment,
          trailing:
              previous != null && endLine(previous) == lineOf(comment.offset),
        ));
      }
    }
    if (token.isEof) break;
    for (var line = lineOf(token.offset); line <= endLine(token); line++) {
      codeLines.add(line);
    }
    previous = token;
  }
  if (found.isEmpty) return const [];
  final sortedCodeLines = codeLines.toList()..sort();
  final firstDeclaration = unit.declarations.isEmpty
      ? null
      : unit.declarations.first.beginToken.offset;
  return [
    for (final (:token, :trailing) in found)
      _read(
        token,
        file: file,
        line: lineOf(token.offset),
        trailing: trailing,
        sortedCodeLines: sortedCodeLines,
        firstDeclaration: firstDeclaration,
      ),
  ];
}

SuppressionComment _read(
  Token token, {
  required String file,
  required int line,
  required bool trailing,
  required List<int> sortedCodeLines,
  required int? firstDeclaration,
}) {
  final match = _comment.firstMatch(token.lexeme)!;
  final forFile = match.group(1) != null;
  final text = match.group(2)!.trim();
  final String id;
  String? reason;
  if (_separator.firstMatch(text) case final separator?) {
    id = text.substring(0, separator.start).trim();
    final after = text.substring(separator.end).trim();
    reason = after.isEmpty ? null : after;
  } else {
    id = text;
  }
  int? first;
  int? last;
  if (!forFile) {
    if (trailing) {
      first = last = line;
    } else {
      // The next line of code, if there is one; the lines between are
      // blank or comments.
      final next = sortedCodeLines.where((code) => code > line).firstOrNull;
      if (next != null) {
        first = line + 1;
        last = next;
      }
    }
  }
  return SuppressionComment(
    file: file,
    line: line,
    forFile: forFile,
    id: id,
    reason: reason,
    firstLine: first,
    lastLine: last,
    afterDeclaration:
        forFile && firstDeclaration != null && token.offset > firstDeclaration,
  );
}
