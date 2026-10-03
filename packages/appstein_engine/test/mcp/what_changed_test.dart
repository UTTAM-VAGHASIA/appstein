import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';
import 'support/sample_delta.dart';

void main() {
  ToolAnswer ask({String? since, String? library}) =>
      whatChanged(sampleDelta, since: since, library: library);

  List<String> ids(Object? notes) => [
    for (final note in (notes! as List).cast<Map<String, Object?>>())
      note['id']! as String,
  ];

  test('without arguments: every note and per-library counts, no entries', () {
    final reply = ask() as ToolReply;
    expect(reply.result['notesFrom'], '3.16');
    expect(ids(reply.result['notes']), [
      'popscope-not-willpopscope',
      'dot-shorthands',
    ]);
    expect(ids(reply.result['laterNotes']), ['dart-primary-constructors']);
    expect(reply.result['libraries'], [
      {
        'library': 'dart:core',
        'deprecated': 1,
        'removed': 0,
        'changed': 0,
        'moved': 0,
      },
      {
        'library': 'package:flutter',
        'deprecated': 4,
        'removed': 2,
        'changed': 1,
        'moved': 1,
      },
      {
        'library': 'package:go_router',
        'deprecated': 1,
        'removed': 1,
        'changed': 0,
        'moved': 0,
      },
    ]);
    expect(reply.result.containsKey('library'), isFalse);
    expect(
      reply.summary,
      '2 curated notes since 3.16 (1 more needs a newer language version); '
      '6 deprecated, 3 removed, 1 changed and 1 moved APIs in 3 libraries. '
      "Ask `check_api` about one name, or pass `library` for a library's "
      'list.',
    );
    expectMatchesSchema(
      ToolSchemas.whatChangedResult,
      withoutNulls(reply.result),
    );
  });

  test('since narrows the notes only', () {
    final reply = ask(since: '3.38') as ToolReply;
    expect(reply.result['notesFrom'], '3.38');
    expect(ids(reply.result['notes']), ['dot-shorthands']);
    expect(ids(reply.result['laterNotes']), ['dart-primary-constructors']);
    expect((reply.result['libraries']! as List).length, 3);
  });

  test('a since older than the baseline starts at the baseline', () {
    final reply = ask(since: '3.10') as ToolReply;
    expect(reply.result['notesFrom'], '3.16');
    expect(reply.summary, contains('the notes start at the baseline, 3.16'));
  });

  test('a library lists its entries in full; package: may be left out', () {
    final reply = ask(library: 'go_router') as ToolReply;
    final entries = reply.result['library']! as Map<String, Object?>;
    expect(entries['library'], 'package:go_router');
    expect(
      (entries['deprecated']! as List).single,
      containsPair('name', 'GoRouter.new(label)'),
    );
    expect(
      (entries['migrated']! as List).single,
      containsPair('name', 'GoRouterState.location'),
    );
    expect(entries['moved'], isEmpty);
    expect(
      reply.summary,
      endsWith(
        '`package:go_router`: 1 deprecated, 1 removed or changed and '
        '0 moved APIs listed.',
      ),
    );
    expectMatchesSchema(
      ToolSchemas.whatChangedResult,
      withoutNulls(reply.result),
    );
  });

  test('a moved library counts under its package', () {
    final reply = ask(library: 'package:flutter') as ToolReply;
    final entries = reply.result['library']! as Map<String, Object?>;
    expect(
      (entries['moved']! as List).single,
      containsPair('from', 'package:flutter/material.dart'),
    );
  });

  test('a library with no entries is refused, listing those that have', () {
    expect(
      (ask(library: 'package:nope') as ToolRefusal).message,
      'No library "package:nope" has deprecated, removed or moved APIs in '
      'the delta. Libraries that do: dart:core, package:flutter, '
      'package:go_router.',
    );
  });

  test('a since that is not a version is refused', () {
    expect(
      (ask(since: 'latest') as ToolRefusal).message,
      '"latest" is not a Flutter version; give one such as `3.27`.',
    );
  });

  test('without API lists: the notes, and why the counts are missing', () {
    final reply = whatChanged(sampleDeltaWithoutApis) as ToolReply;
    expect(reply.result['libraries'], isEmpty);
    expect(
      reply.result['apiListsMissing'],
      'the packages could not be fetched',
    );
    expect(
      (whatChanged(sampleDeltaWithoutApis, library: 'go_router') as ToolRefusal)
          .message,
      'The API lists are missing: the packages could not be fetched.',
    );
  });
}
