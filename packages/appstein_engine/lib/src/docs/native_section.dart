import 'package:appstein_protocol/appstein_protocol.dart';

import 'markdown_text.dart';

/// The page every platform pack writes its section into (spec §6.9).
const nativePagePath = 'native.md';

/// The title of [nativePagePath].
const nativePageTitle = 'Native setup';

/// What a hidden value that follows the installed Flutter SDK says in its
/// cell; a platform's section explains it once ([platformSection]).
const followsFlutter = 'follows the Flutter SDK in use';

/// Which of a pack's native values the project's own files don't fix, by
/// where the value came from (`NativeValue.resolvedFrom`).
///
/// The pages are committed, so they must be the same on every teammate's
/// machine and in CI (spec §6.9). A value that isn't the same everywhere is
/// never written on a page as if it were.
final class NativeSources {
  /// Creates the sets.
  const NativeSources({this.sdk = const {}, this.machine = const {}});

  /// The sources whose value follows the Flutter SDK a machine has, such as
  /// `flutter`. Its value is shown only in a project that pins Flutter:
  /// then every machine resolves the same one.
  final Set<String> sdk;

  /// The sources that are settings of one machine, such as its global
  /// Flutter config. Their values are never shown.
  final Set<String> machine;
}

/// Where and how one page renders native values.
typedef _Context = ({
  String docsPath,
  String page,
  NativeSources sources,
  bool flutterPinned,
});

final _placeLine = RegExp(r'^(.*):(\d+)$');

String _place(String? at, _Context context) {
  if (at == null) return '';
  final match = _placeLine.firstMatch(at);
  return projectLink(
    docsPath: context.docsPath,
    page: context.page,
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
/// - A found value the project doesn't fix ([sources]) is not shown: one
///   that follows the Flutter SDK says so, unless [flutterPinned]; a
///   setting of one machine says so always.
/// - An unknown value is `unknown:` and the reason. It is never guessed.
/// - An absent value is `not set:` and the reason.
({String value, String where}) nativeCells(
  NativeValue value, {
  required String docsPath,
  required String page,
  NativeSources sources = const NativeSources(),
  bool flutterPinned = true,
}) => _cells(value, (
  docsPath: docsPath,
  page: page,
  sources: sources,
  flutterPinned: flutterPinned,
));

({String value, String where}) _cells(NativeValue value, _Context context) {
  final from = value.resolvedFrom;
  final String text;
  // Found or unknown: an unknown value's reason is one machine's too when
  // the value would have come from that machine or its Flutter.
  if (context.sources.machine.contains(from)) {
    text = 'set on each machine (${mdCode(from!)}), so it is not shown here';
  } else if (context.sources.sdk.contains(from) && !context.flutterPinned) {
    text = switch (value.expression) {
      final expression? =>
        'written as ${mdCode(expression)}; the value $followsFlutter',
      null => followsFlutter,
    };
  } else {
    text = switch (value.status) {
      NativeStatus.found => [
        switch (value.value) {
          final List<Object?> items when items.isEmpty => 'none',
          final List<Object?> items =>
            items.map((item) => mdCode('$item')).join(', '),
          final other => mdCode('$other'),
        },
        if (value.expression case final expression?)
          ', written as ${mdCode(expression)}',
        if (from != null) ' (from ${mdText(from)})',
        if (value.note case final note?) '; ${mdText(note)}',
      ].join(),
      NativeStatus.unknown => 'unknown: ${mdText(value.reason ?? 'no reason')}',
      NativeStatus.absent => 'not set: ${mdText(value.reason ?? 'no reason')}',
      NativeStatus.error =>
        'Appstein failed to read this '
            '(${mdText(value.errorType ?? 'error')}). Please report it.',
    };
  }
  return (value: text, where: _place(value.at, context));
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
/// left out by accident. [omit] names the parts of [group] that are left
/// out on purpose, because they differ between machines. [sources] and
/// [flutterPinned] are as in [nativeCells]. The first heading is at
/// [level].
String nativeTables(
  NativeGroup group, {
  required String docsPath,
  required String page,
  Map<String, String> headings = const {},
  List<String> order = const [],
  Set<String> omit = const {},
  NativeSources sources = const NativeSources(),
  bool flutterPinned = true,
  int level = 3,
}) => _tables(
  group,
  (
    docsPath: docsPath,
    page: page,
    sources: sources,
    flutterPinned: flutterPinned,
  ),
  headings: headings,
  order: order,
  omit: omit,
  level: level,
);

String _tables(
  NativeGroup group,
  _Context context, {
  Map<String, String> headings = const {},
  List<String> order = const [],
  Set<String> omit = const {},
  required int level,
}) {
  final children = group.children;
  final keys = [
    for (final key in order)
      if (children.containsKey(key)) key,
    ...(children.keys.where((key) => !order.contains(key)).toList()..sort()),
  ].where((key) => !omit.contains(key)).toList();
  String heading(String key, int at) =>
      '${'#' * at} ${headings[key] ?? mdCode(key)}';

  final blocks = <String>[
    mdTable(
      const ['Setting', 'Value', 'Where'],
      [
        for (final key in keys)
          if (children[key] case final NativeValue value)
            switch (_cells(value, context)) {
              (:final value, :final where) => [mdCode(key), value, where],
            },
      ],
    ).trimRight(),
    for (final key in keys)
      switch (children[key]) {
        final NativeGroup child => [
          heading(key, level),
          _tables(child, context, level: level + 1),
        ].where((block) => block.isNotEmpty).join('\n\n'),
        final NativeList list =>
          '${heading(key, level)}\n\n${_list(list, context, level + 1)}',
        _ => '',
      },
  ];
  return blocks.where((block) => block.isNotEmpty).join('\n\n');
}

String _list(NativeList list, _Context context, int level) {
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
          _place(entry.at, context),
          for (final column in columns)
            switch (entry.children[column]) {
              final NativeValue value => switch (_cells(value, context)) {
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
            '${_tables(more, context, level: level + 1)}',
  ];
  return [table, ...rest].join('\n\n');
}

/// A platform's section of [nativePagePath]: [heading], the [concepts]
/// (the pack's own text), then what `map/native.json` holds for it, as
/// [nativeTables] renders it with [headings], [order], [omit], [sources]
/// and [flutterPinned].
///
/// When a value was hidden because it follows the installed Flutter SDK,
/// one sentence after the concepts says what that means and how to see the
/// numbers.
///
/// A [section] that is one value, such as a missing platform folder, is
/// the heading and one sentence with the reason. Null when [section] is
/// null: the pack has nothing in the map.
String? platformSection(
  NativeNode? section, {
  required String heading,
  required List<String> concepts,
  required String docsPath,
  required bool flutterPinned,
  Map<String, String> headings = const {},
  List<String> order = const [],
  Set<String> omit = const {},
  NativeSources sources = const NativeSources(),
}) {
  if (section == null) return null;
  final _Context context = (
    docsPath: docsPath,
    page: nativePagePath,
    sources: sources,
    flutterPinned: flutterPinned,
  );
  String tables(NativeGroup group) {
    final text = _tables(
      group,
      context,
      headings: headings,
      order: order,
      omit: omit,
      level: 3,
    );
    return [
      concepts.map((concept) => '- $concept').join('\n'),
      if (text.contains(followsFlutter))
        'Here, "$followsFlutter" means the number comes from the Flutter '
            "each machine has, so it isn't written on this page. Pin Flutter "
            'in the project, for example with FVM, to see the numbers.',
      text,
    ].where((block) => block.isNotEmpty).join('\n\n');
  }

  final body = switch (section) {
    NativeValue(status: NativeStatus.absent, :final reason) =>
      'Not set up in this project: ${mdText(reason ?? 'no reason')}.',
    final NativeValue value =>
      '${_cells(value, context).value}'
          '${value.status == NativeStatus.unknown ? '.' : ''}',
    final NativeGroup group => tables(group),
    final NativeList list => _list(list, context, 3),
  };
  return '## $heading\n\n$body';
}
