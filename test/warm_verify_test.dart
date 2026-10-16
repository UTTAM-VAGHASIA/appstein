import 'package:test/test.dart';

import '../tool/src/warm_verify.dart';

/// A `tools/call` result of `verify` with these findings, as `appstein mcp`
/// sends it: the findings are in `structuredContent`.
Map<String, Object?> reply(
  List<Map<String, Object?>> findings, {
  bool isError = false,
}) => {
  'isError': isError,
  'content': [
    {'type': 'text', 'text': 'Fast verify.'},
  ],
  if (!isError) 'structuredContent': {'findings': findings},
};

Map<String, Object?> error(String file, int line) => {
  'id': 'dart.error',
  'file': file,
  'line': line,
  'message': "A value of type 'String' can't be returned.",
};

void main() {
  group('editWithError', () {
    const original = '/// A.\nclass A {}\n';

    test('keeps the file and adds the error, on the line it returns', () {
      for (var n = 0; n < 6; n++) {
        final edit = editWithError(original, n);
        expect(edit.text, startsWith(original));
        final lines = edit.text.split('\n');
        expect(lines[edit.line - 1], startsWith('int wrong$n()'));
      }
    });

    test('puts the error on a different line and in a different size each '
        'time, so a reply left from an earlier edit is wrong', () {
      final edits = [for (var n = 0; n < 6; n++) editWithError(original, n)];
      expect({for (final edit in edits) edit.line}, hasLength(6));
      expect({for (final edit in edits) edit.text.length}, hasLength(6));
    });

    test('the line counts the original, the blank lines and the comment', () {
      // `original` has 2 lines and ends with a newline; the edit adds one
      // empty line, then the doc comment on line 4, the declaration on 5.
      expect(editWithError(original, 0).line, 5);
      expect(editWithError(original, 2).line, 7);
    });
  });

  group('medianOf', () {
    test('is the middle time, whatever the order they were taken in', () {
      expect(
        medianOf(const [
          Duration(seconds: 9),
          Duration(seconds: 1),
          Duration(seconds: 3),
        ]),
        const Duration(seconds: 3),
      );
    });

    test('of one time is that time', () {
      expect(
        medianOf(const [Duration(seconds: 2)]),
        const Duration(seconds: 2),
      );
    });
  });

  group('warmLimitMiss', () {
    test('is null just under 5 s', () {
      expect(warmLimitMiss(Duration.zero), isNull);
      expect(warmLimitMiss(const Duration(milliseconds: 4999)), isNull);
      expect(warmLimitMiss(const Duration(microseconds: 4999999)), isNull);
    });

    test('fails at exactly 5 s: the design says under 5 s', () {
      expect(warmLimitMiss(const Duration(seconds: 5)), isNotNull);
    });

    test('names the measured time when it is 5 s or more, and the limit', () {
      final message = warmLimitMiss(const Duration(milliseconds: 5001));
      expect(message, contains('5001 ms'));
      expect(message, contains('5 s'));
      expect(message, contains('median'));
    });
  });

  group('missedError', () {
    const file = 'lib/ui/feature_9/view_models/feature_9_view_model.dart';

    test('is null when the reply reports the error on that file and line', () {
      expect(
        missedError(reply([error(file, 12)]), file: file, line: 12),
        isNull,
      );
    });

    test('names a reply that reports no findings at all: a fast answer '
        'that missed the change', () {
      final problem = missedError(reply([]), file: file, line: 12);
      expect(problem, contains(file));
      expect(problem, contains('dart.error'));
    });

    test('does not take an error in another file, or on another line', () {
      expect(
        missedError(reply([error('lib/other.dart', 12)]), file: file, line: 12),
        isNotNull,
      );
      expect(
        missedError(reply([error(file, 3)]), file: file, line: 12),
        isNotNull,
      );
    });

    test('does not take another finding on that line', () {
      final warning = {...error(file, 12), 'id': 'dart.warning'};
      expect(missedError(reply([warning]), file: file, line: 12), isNotNull);
    });

    test('an error reply is a problem, with its text', () {
      final problem = missedError(
        reply([], isError: true),
        file: file,
        line: 12,
      );
      expect(problem, contains('error'));
      expect(problem, contains('Fast verify.'));
    });

    test('a reply with no structured content is a problem', () {
      expect(missedError({'isError': false}, file: file, line: 1), isNotNull);
      expect(
        missedError(
          {
            'structuredContent': {'findings': 'none'},
          },
          file: file,
          line: 1,
        ),
        isNotNull,
      );
    });
  });

  group('unexpectedError', () {
    const file = 'lib/a.dart';

    test('is null when the file has no error', () {
      expect(unexpectedError(reply([]), file: file), isNull);
      expect(
        unexpectedError(reply([error('lib/b.dart', 1)]), file: file),
        isNull,
      );
    });

    test('names an error that is still on the file', () {
      expect(
        unexpectedError(reply([error(file, 4)]), file: file),
        contains('$file:4'),
      );
    });

    test('with no file, any dart.error is unexpected', () {
      expect(
        unexpectedError(reply([error('lib/b.dart', 2)])),
        contains('lib/b.dart:2'),
      );
      expect(unexpectedError(reply([])), isNull);
    });

    test('an error reply is a problem', () {
      expect(unexpectedError(reply([], isError: true)), isNotNull);
    });
  });
}
