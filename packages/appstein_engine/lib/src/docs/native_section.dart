import 'package:appstein_protocol/appstein_protocol.dart';

import 'markdown_text.dart';

/// The page every platform pack writes its section into (spec §6.9).
const nativePagePath = 'native.md';

/// The title of [nativePagePath].
const nativePageTitle = 'Native setup';

final _placeLine = RegExp(r'^(.*):(\d+)$');

String _place(String? at, {required String docsPath, required String page}) {
  if (at == null) return '';
  final match = _placeLine.firstMatch(at);
  return projectLink(
    docsPath: docsPath,
    page: page,
    target: match == null ? at : match[1]!,
    line: match == null ? null : int.parse(match[2]!),
  );
}

/// One native value as two table cells: what it is, and where it is, as a
/// link from the page at [page].
///
/// - A found value is shown as code; a list as its items; with an
///   expression, how the file wrote it and where its value came from; then
///   its note.
/// - An unknown value is `unknown:` and the reason. It is never guessed.
/// - An absent value is `not set:` and the reason.
({String value, String where}) nativeCells(
  NativeValue value, {
  required String docsPath,
  required String page,
}) {
  final text = switch (value.status) {
    NativeStatus.found => [
      switch (value.value) {
        final List<Object?> items when items.isEmpty => 'none',
        final List<Object?> items => items.map((i) => mdCode('$i')).join(', '),
        final other => mdCode('$other'),
      },
      if (value.expression case final expression?)
        ', written as ${mdCode(expression)}',
      if (value.resolvedFrom case final from?) ' (from ${mdText(from)})',
      if (value.note case final note?) '; ${mdText(note)}',
    ].join(),
    NativeStatus.unknown => 'unknown: ${mdText(value.reason ?? 'no reason')}',
    NativeStatus.absent => 'not set: ${mdText(value.reason ?? 'no reason')}',
    NativeStatus.error =>
      'Appstein failed to read this (${mdText(value.errorType ?? 'error')}). '
          'Please report it.',
  };
  return (value: text, where: _place(value.at, docsPath: docsPath, page: page));
}

/// Every part of [group] as Markdown, for the page at [page]:
/// - its own values as one table, `Setting | Value | Where`;
/// - each group inside it under a heading, the same way, one level deeper;
/// - each list under a heading, as a table with one row per entry and one
///   column per value the entries have, or `None.` when it is empty.
///
/// [headings] gives the heading of a part of [group] by its key; a part
/// without one is headed by its key. [order] names the parts that come
/// first; every other part follows, sorted, so nothing in the section is
/// left out. The first heading is at [level].
String nativeTables(
  NativeGroup group, {
  required String docsPath,
  required String page,
  Map<String, String> headings = const {},
  List<String> order = const [],
  int level = 3,
}) {
  final children = group.children;
  final keys = [
    for (final key in order)
      if (children.containsKey(key)) key,
    ...(children.keys.where((key) => !order.contains(key)).toList()..sort()),
  ];
  String heading(String key, int at) =>
      '${'#' * at} ${headings[key] ?? mdCode(key)}';

  final blocks = <String>[
    mdTable(
      const ['Setting', 'Value', 'Where'],
      [
        for (final key in keys)
          if (children[key] case final NativeValue value)
            switch (nativeCells(value, docsPath: docsPath, page: page)) {
              (:final value, :final where) => [mdCode(key), value, where],
            },
      ],
    ).trimRight(),
    for (final key in keys)
      switch (children[key]) {
        final NativeGroup child => [
          heading(key, level),
          nativeTables(child, docsPath: docsPath, page: page, level: level + 1),
        ].where((block) => block.isNotEmpty).join('\n\n'),
        final NativeList list =>
          '${heading(key, level)}\n\n'
              '${_list(list, docsPath: docsPath, page: page, level: level + 1)}',
        _ => '',
      },
  ];
  return blocks.where((block) => block.isNotEmpty).join('\n\n');
}

String _list(
  NativeList list, {
  required String docsPath,
  required String page,
  required int level,
}) {
  if (list.entries.isEmpty) return 'None.';
  final columns = {
    for (final entry in list.entries)
      for (final MapEntry(:key, :value) in entry.children.entries)
        if (value is NativeValue) key,
  }.toList()..sort();
  final table = mdTable(
    ['Name', 'Declared at', ...columns.map(mdCode)],
    [
      for (final entry in list.entries)
        [
          mdCode(entry.name),
          _place(entry.at, docsPath: docsPath, page: page),
          for (final column in columns)
            switch (entry.children[column]) {
              final NativeValue value => switch (nativeCells(
                value,
                docsPath: docsPath,
                page: page,
              )) {
                (:final value, :final where) =>
                  where.isEmpty ? value : '$value ($where)',
              },
              _ => '',
            },
        ],
    ],
  ).trimRight();
  // What an entry holds besides plain values, under its own heading.
  final rest = [
    for (final entry in list.entries)
      if (NativeGroup({
            for (final MapEntry(:key, :value) in entry.children.entries)
              if (value is! NativeValue) key: value,
          })
          case final more when more.children.isNotEmpty)
        '${'#' * level} ${mdCode(entry.name)}\n\n'
            '${nativeTables(more, docsPath: docsPath, page: page, level: level + 1)}',
  ];
  return [table, ...rest].join('\n\n');
}

/// A platform's section of [nativePagePath]: [heading], the [concepts]
/// (the pack's own text), then what `map/native.json` holds for it.
///
/// A [section] that is one value, such as a missing platform folder, is
/// the heading and one sentence with the reason. Null when [section] is
/// null: the pack has nothing in the map.
String? platformSection(
  NativeNode? section, {
  required String heading,
  required List<String> concepts,
  required String docsPath,
  Map<String, String> headings = const {},
  List<String> order = const [],
}) {
  if (section == null) return null;
  final body = switch (section) {
    NativeValue(status: NativeStatus.absent, :final reason) =>
      'Not set up in this project: ${mdText(reason ?? 'no reason')}.',
    NativeValue(status: NativeStatus.found) && final value => nativeCells(
      value,
      docsPath: docsPath,
      page: nativePagePath,
    ).value,
    final NativeValue value =>
      '${nativeCells(value, docsPath: docsPath, page: nativePagePath).value}'
          '${value.status == NativeStatus.unknown ? '.' : ''}',
    final NativeGroup group => [
      concepts.map((concept) => '- $concept').join('\n'),
      nativeTables(
        group,
        docsPath: docsPath,
        page: nativePagePath,
        headings: headings,
        order: order,
      ),
    ].where((block) => block.isNotEmpty).join('\n\n'),
    final NativeList list => _list(
      list,
      docsPath: docsPath,
      page: nativePagePath,
      level: 3,
    ),
  };
  return '## $heading\n\n$body';
}
