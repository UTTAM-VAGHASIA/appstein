import 'package:test/test.dart';

import '../tool/src/coverage.dart';
import '../tool/src/stale_check.dart';

final map = CoverMap({
  'docs/guide/doctor.md': const CoversComment([
    'packages/engine/lib/src/doctor/**',
  ], 1),
  'docs/guide/sdk-lookups.md': const CoversComment([
    'packages/engine/lib/src/sdk/**',
  ], 1),
  'docs/guide/how-to/add-a-check.md': const CoversComment([
    'packages/engine/lib/src/doctor/doctor_check.dart',
  ], 1),
});

List<String> stale(List<String> changed, [List<String> messages = const []]) =>
    [
      for (final problem in checkStale(
        map: map,
        changed: changed,
        messages: messages,
      ))
        '$problem',
    ];

void main() {
  test('passes when the covering page changed too', () {
    expect(
      stale(['packages/engine/lib/src/doctor/a.dart', 'docs/guide/doctor.md']),
      isEmpty,
    );
  });

  test('passes when any one of several covering pages changed', () {
    expect(
      stale([
        'packages/engine/lib/src/doctor/doctor_check.dart',
        'docs/guide/how-to/add-a-check.md',
      ]),
      isEmpty,
    );
  });

  test('ignores files no page covers', () {
    expect(stale(['README.md', 'packages/engine/test/x_test.dart']), isEmpty);
  });

  test('reports a changed file whose page did not change, with the '
      'trailer to use', () {
    expect(stale(['packages/engine/lib/src/sdk/fvm.dart']), [
      'packages/engine/lib/src/sdk/fvm.dart: Changed, but the page that '
          'explains it did not: docs/guide/sdk-lookups.md. Update the page, '
          'or if it is still right, add a commit trailer: '
          'Docs-Checked: sdk-lookups.md - <why it is still right>',
    ]);
  });

  test('a deleted or renamed file counts like an edit', () {
    expect(stale(['packages/engine/lib/src/doctor/old.dart']), [
      startsWith('packages/engine/lib/src/doctor/old.dart: Changed'),
    ]);
  });

  for (final message in [
    'Refactor\n\nDocs-Checked: sdk-lookups.md - only renamed a private helper',
    'Tidy\r\n\r\ndocs-checked: docs/guide/sdk-lookups.md - no behaviour '
        'change\r\n',
  ]) {
    test('a Docs-Checked trailer clears it: ${message.split('\n').first}', () {
      expect(
        stale(['packages/engine/lib/src/sdk/fvm.dart'], [message]),
        isEmpty,
      );
    });
  }

  test('a trailer for a different page does not clear it', () {
    expect(
      stale(
        ['packages/engine/lib/src/sdk/fvm.dart'],
        ['x\n\nDocs-Checked: doctor.md - unrelated'],
      ),
      hasLength(1),
    );
  });

  test('rejects trailers without a reason or naming no guide page', () {
    expect(
      stale([], [
        'a\n\nDocs-Checked: doctor.md',
        'b\n\nDocs-Checked: nope.md - why',
      ]),
      [
        'commit message: Write the trailer as '
            '`Docs-Checked: <page> - <reason>`: Docs-Checked: doctor.md',
        'commit message: Docs-Checked names docs/guide/nope.md, which is not '
            'a guide page.',
      ],
    );
  });
}
