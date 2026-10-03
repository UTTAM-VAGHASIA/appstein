import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `check_api` (spec §8): whether the API [name] is deprecated or removed
/// for the project, from [delta] (`delta.json`).
///
/// [name] may be a class or function (`WillPopScope`), a member alone or
/// with its class (`withOpacity`, `Color.withOpacity`), a setter without
/// its `=` (`colour`), a parameter (`Text.new(textScaleFactor)`), a library
/// URI, or any of these followed by `()`. It matches:
/// - the deprecated and the removed or changed APIs: by full name; by a
///   member's own name when [name] has no `.`; and the parameters of the
///   member [name] (or a parameter of that name);
/// - the moved libraries, by URI;
/// - the curated notes whose `avoid` names it as a whole word.
///
/// The status is `removed` when a removed API matches, otherwise
/// `deprecated` when an API deprecated for any use matches, otherwise `ok`
/// (spec §6.4: another deprecation kind forbids only that one use).
/// Parameters, changed APIs, moved libraries and notes are listed without
/// changing the status. `ok` means nothing the project imports deprecates
/// or removes the name; whether it exists isn't checked.
ToolAnswer checkApi(String name, DeltaKnowledge delta) {
  final input = name.trim().replaceFirst(RegExp(r'\(\)$'), '');
  if (input.isEmpty) {
    return const ToolRefusal(
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  }
  final apis = delta.apis;
  final matches = <Map<String, Object?>>[];
  var removed = false;
  var deprecated = false;
  final removals = <String>[];
  final deprecations = <String>[];
  final rules = <String>[];
  var parameters = false;
  if (apis != null) {
    for (final api in apis.deprecated) {
      final match = _match(api.name, input);
      if (match == null) continue;
      final parameter = match == _Match.parameter;
      parameters |= parameter;
      if (!parameter) {
        if (api.kind == 'use') {
          deprecated = true;
          deprecations.add(api.message ?? 'deprecated, with no message');
        } else if (api.rule case final rule?) {
          rules.add(rule);
        }
      }
      matches.add({
        'kind': 'deprecated',
        'library': api.library,
        'name': api.name,
        'deprecationKind': api.kind,
        'rule': ?api.rule,
        'message': ?api.message,
        if (api.migrations.isNotEmpty) 'migrations': api.migrations,
        if (parameter) 'parameter': true,
      });
    }
    for (final api in apis.migrated) {
      final match = _match(api.name, input);
      if (match == null) continue;
      final parameter = match == _Match.parameter;
      parameters |= parameter;
      if (!parameter && api.status == 'removed') {
        removed = true;
        removals.add(api.title);
      }
      matches.add({
        'kind': api.status,
        'library': api.library,
        'name': api.name,
        'migration': api.title,
        if (parameter) 'parameter': true,
      });
    }
    for (final moved in apis.moved) {
      if (moved.from != input) continue;
      matches.add({
        'kind': 'moved',
        'name': moved.from,
        'to': ?moved.to,
        'migration': moved.title,
      });
    }
  }
  final terms = {input, if (input.contains('.')) input.split('.').last};
  var notes = 0;
  for (final note in [...delta.notes, ...delta.laterNotes]) {
    if (!terms.any((term) => _namesWord(note.avoid, term))) continue;
    notes++;
    matches.add({
      'kind': 'note',
      'id': note.id,
      'summary': note.summary,
      'use': note.use,
      'avoid': note.avoid,
      'source': note.source,
    });
  }
  final status = removed
      ? 'removed'
      : deprecated
      ? 'deprecated'
      : 'ok';
  final incomplete = apis == null
      ? 'Only the curated notes were checked: the API lists are missing '
            '(${delta.missing}).'
      : null;
  final summary = [
    ?incomplete,
    switch (status) {
      'removed' => '`$input` is removed: ${_withFullStop(removals.first)}',
      'deprecated' =>
        '`$input` is deprecated: ${_withFullStop(deprecations.first)}',
      _ =>
        '`$input` is ok: nothing the project imports deprecates or removes '
            'it.',
    },
    if (status == 'ok' && rules.isNotEmpty)
      'Its deprecation forbids only this: ${rules.first}',
    if (status == 'ok' && parameters)
      'Some of its parameters are deprecated or removed; see `matches`.',
    if (notes > 0)
      '$notes curated ${notes == 1 ? 'note mentions' : 'notes mention'} it.',
  ].join(' ');
  return ToolReply({
    'name': input,
    'status': status,
    'matches': matches,
    if (status == 'ok')
      'meaning':
          'Nothing the project imports deprecates or removes `$input`. '
          "Whether it exists isn't checked here; the Dart MCP server's "
          'analyzer does that.',
    'incomplete': ?incomplete,
  }, summary);
}

enum _Match { exact, member, parameter }

/// How the API named [entry] in the delta matches [input], or null.
_Match? _match(String entry, String input) {
  if (entry == input) return _Match.exact;
  if (input.contains('(')) return null;
  final paren = entry.indexOf('(');
  if (paren >= 0) {
    final member = entry.substring(0, paren);
    final parameter = entry.substring(paren + 1, entry.length - 1);
    return member == input || parameter == input ? _Match.parameter : null;
  }
  if (input.contains('.')) return null;
  final member = entry.endsWith('=')
      ? entry.substring(0, entry.length - 1)
      : entry;
  return member.split('.').last == input ? _Match.member : null;
}

/// Whether [text] has [term] as a whole word: not inside a longer name.
bool _namesWord(String text, String term) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(term)}(?![A-Za-z0-9_])',
).hasMatch(text);

String _withFullStop(String text) {
  final trimmed = text.trim();
  return trimmed.endsWith('.') ? trimmed : '$trimmed.';
}
