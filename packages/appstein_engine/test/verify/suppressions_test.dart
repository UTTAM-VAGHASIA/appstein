import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/verify_support.dart';

SuppressionEntry _entry(
  String id,
  String path, {
  String? reason = 'Accepted for now.',
  int line = 7,
}) => SuppressionEntry(id: id, path: path, reason: reason, line: line);

const _known = {'docs.stale', 'decision.drift', ...unsuppressibleIds};

({List<Finding> kept, int suppressed}) _apply(
  List<Finding> findings,
  List<SuppressionEntry> entries, {
  VerifyMode mode = VerifyMode.full,
}) => applySuppressions(findings, entries, knownIds: _known, mode: mode);

List<String> _ids(List<Finding> findings) => [
  for (final finding in findings) finding.id,
];

void main() {
  test('an entry with a reason hides its finding', () {
    final result = _apply(
      [finding('docs.stale', file: 'docs/app/routes.md')],
      [_entry('docs.stale', 'docs/app/routes.md')],
    );
    expect(result.kept, isEmpty);
    expect(result.suppressed, 1);
  });

  test('it hides only that check, and only on that path', () {
    final result = _apply(
      [
        finding('docs.stale', file: 'docs/app/routes.md'),
        finding('decision.drift', file: 'docs/app/routes.md'),
        finding('docs.stale', file: 'docs/app/native.md'),
      ],
      [_entry('docs.stale', 'docs/app/routes.md')],
    );
    expect(
      [for (final f in result.kept) '${f.id} ${f.file}'],
      ['decision.drift docs/app/routes.md', 'docs.stale docs/app/native.md'],
    );
    expect(result.suppressed, 1);
  });

  test('a glob and a folder both match files below them', () {
    for (final path in ['docs/app/**', 'docs/app', 'docs/**/home.md']) {
      final result = _apply(
        [finding('docs.stale', file: 'docs/app/features/home.md')],
        [_entry('docs.stale', path)],
      );
      expect(result.kept, isEmpty, reason: path);
    }
    // A name that only starts the same is another folder.
    final other = _apply(
      [finding('docs.stale', file: 'docs/apparel/x.md')],
      [_entry('docs.stale', 'docs/app')],
    );
    expect(_ids(other.kept), ['docs.stale', 'suppression.unused']);
  });

  test('a finding about the whole project is never hidden', () {
    final result = _apply(
      [finding('docs.stale')],
      [_entry('docs.stale', '**')],
    );
    expect(_ids(result.kept), ['docs.stale', 'suppression.unused']);
    expect(result.suppressed, 0);
  });

  test('one entry may hide several findings', () {
    final result = _apply(
      [
        for (final page in ['a', 'b', 'c'])
          finding('docs.stale', file: 'docs/app/$page.md'),
      ],
      [_entry('docs.stale', 'docs/app/*.md')],
    );
    expect(result.kept, isEmpty);
    expect(result.suppressed, 3);
  });

  test('without a reason it hides nothing and is an error', () {
    final result = _apply(
      [finding('docs.stale', file: 'docs/app/routes.md')],
      [_entry('docs.stale', 'docs/app/routes.md', reason: null, line: 12)],
    );
    expect(_ids(result.kept), ['docs.stale', 'suppression.no_reason']);
    expect(result.suppressed, 0);
    final problem = result.kept.last;
    expect(problem.severity, Severity.error);
    expect(problem.file, 'appstein.yaml');
    expect(problem.line, 12);
    expect(
      problem.message,
      'The suppression of `docs.stale` on `docs/app/routes.md` has no '
      'reason, so it hides nothing.',
    );
    expect(problem.fixHint, contains('reason:'));
  });

  test('an ID no check has is an error, with the likely one', () {
    final result = _apply(
      [finding('docs.stale', file: 'docs/app/routes.md')],
      [_entry('docs.stael', 'docs/app/routes.md', line: 3)],
    );
    expect(_ids(result.kept), ['docs.stale', 'suppression.unknown_check']);
    final problem = result.kept.last;
    expect(problem.severity, Severity.error);
    expect((problem.file, problem.line), ('appstein.yaml', 3));
    expect(problem.message, 'No check of this project reports `docs.stael`.');
    expect(problem.fixHint, 'Did you mean `docs.stale`?');
  });

  test('an unknown ID with nothing like it has no guess', () {
    final result = _apply([], [_entry('zzz.qqqqqqqq', 'a')]);
    expect(result.kept.single.fixHint, isNull);
  });

  test('a finding that cannot be suppressed stays, and the entry is an '
      'error', () {
    for (final id in unsuppressibleIds) {
      final result = _apply(
        [finding(id, file: 'appstein.yaml')],
        [_entry(id, 'appstein.yaml')],
      );
      expect(_ids(result.kept), [id, 'suppression.unknown_check'], reason: id);
      expect(result.kept.last.message, "`$id` can't be suppressed.");
      expect(result.kept.last.fixHint, contains('Remove this entry'));
      expect(result.suppressed, 0);
    }
  });

  test('an entry that hides nothing is a warning, in full mode only', () {
    final entries = [_entry('docs.stale', 'docs/app/routes.md', line: 9)];
    final full = _apply([], entries);
    expect(_ids(full.kept), ['suppression.unused']);
    final problem = full.kept.single;
    expect(problem.severity, Severity.warning);
    expect((problem.file, problem.line), ('appstein.yaml', 9));
    expect(
      problem.message,
      'The suppression of `docs.stale` on `docs/app/routes.md` hides no '
      'finding.',
    );
    expect(problem.fixHint, contains('Remove it'));

    expect(_apply([], entries, mode: VerifyMode.fast).kept, isEmpty);
  });

  test('each problem entry is reported once, in file order', () {
    final result = _apply([], [
      _entry('docs.stale', 'a', reason: null, line: 2),
      _entry('nope.nope', 'b', reason: null, line: 5),
      _entry('decision.drift', 'c', line: 8),
    ]);
    expect(
      [for (final f in result.kept) '${f.line} ${f.id}'],
      [
        '2 suppression.no_reason',
        '5 suppression.no_reason',
        '8 suppression.unused',
      ],
    );
  });
}
