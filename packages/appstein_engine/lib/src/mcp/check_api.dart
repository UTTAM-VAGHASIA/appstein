import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `check_api` (spec §8): whether the API [name] is deprecated or removed
/// for the project, from [delta] (`delta.json`).
///
/// [name] may be a class or function (`WillPopScope`), a member alone or
/// with its class (`withOpacity`, `Color.withOpacity`), a setter with or
/// without its `=`, an expression as written in code (`color.withOpacity`,
/// `.withOpacity`, `withOpacity(0.5)`), a constructor (`Text()` is
/// `Text.new`), a parameter (`Text.new(textScaleFactor)`,
/// `Text(textScaleFactor)` or `textScaleFactor`), or a library URI
/// (`package:flutter/material.dart`, `flutter/material.dart`).
///
/// An entry whose name equals [name] matches exactly. Only when no such
/// entry exists does a looser match apply: a member of the same name under
/// any class (the delta names an inherited member by its declaring class).
/// A looser match answers like an exact one (`deprecated` or `removed`; `ok`
/// when the deprecation is of a kind other than `use`), and the summary names
/// the entry that matched, with its library, so the caller can judge. Type
/// arguments (`MaterialStateProperty<Color>`) are ignored. When nothing is
/// deprecated or removed, a member of a deprecated or removed class
/// (`MaterialStateProperty.all`, `WillPopScope.new`) answers like its class,
/// and the summary names the class. The matches are:
/// - the deprecated and the removed or changed APIs;
/// - the parameters of a member ([name] `Text.new` lists
///   `Text.new(textScaleFactor)` without changing the status);
/// - the moved libraries, by URI;
/// - the curated notes whose `avoid` names the identifier as a whole word.
///
/// The status is `removed` when a removed API matches, otherwise
/// `deprecated` when an API deprecated for any use matches, otherwise `ok`
/// (spec §6.4: another deprecation kind forbids only that one use).
/// Changed APIs, moved libraries, notes and the parameters of a member are
/// listed without changing the status. `ok` means nothing the project
/// imports deprecates or removes the name; whether it exists isn't checked.
ToolAnswer checkApi(String name, DeltaKnowledge delta) {
  final query = _Query.parse(name);
  if (query.display.isEmpty) {
    return const ToolRefusal(
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  }
  final apis = delta.apis;
  final hits = <_Hit>[];
  if (apis != null) {
    var found = _collect(apis, query);
    if (found.isEmpty && query.parameter != null) {
      // `Color.withOpacity(x)`: the identifier was an argument, not a
      // parameter name.
      found = _collect(apis, query.withoutParameter());
    }
    hits.addAll(found);
  }
  if (hits.any((hit) => hit.how == _How.exact)) {
    hits.removeWhere((hit) => hit.how == _How.loose);
  }
  if (apis != null &&
      query.container != null &&
      !hits.any((hit) => hit.status != 'ok')) {
    // The delta lists only elements with their own `@Deprecated`, so a member
    // of a deprecated or removed class isn't in it: ask about the class.
    hits.addAll(_classHits(apis, query.container!));
  }
  final matches = <Map<String, Object?>>[];
  final removals = <_Hit>[];
  final deprecations = <_Hit>[];
  final rules = <String>[];
  var parameters = false;
  for (final hit in hits) {
    if (hit.how == _How.owner) parameters = true;
    if (hit.how != _How.owner && hit.status == 'removed') removals.add(hit);
    if (hit.how != _How.owner && hit.status == 'deprecated') {
      deprecations.add(hit);
    }
    if (hit.how != _How.owner && hit.rule != null) rules.add(hit.rule!);
    matches.add(hit.json);
  }
  if (apis != null) {
    for (final moved in apis.moved) {
      if (!query.namesLibrary(moved.from)) continue;
      matches.add({
        'kind': 'moved',
        'name': moved.from,
        'to': ?moved.to,
        'migration': moved.title,
      });
    }
  }
  var notes = 0;
  for (final note in [...delta.notes, ...delta.laterNotes]) {
    if (!query.noteTerms.any((term) => _namesWord(note.avoid, term))) continue;
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
  final status = removals.isNotEmpty
      ? 'removed'
      : deprecations.isNotEmpty
      ? 'deprecated'
      : 'ok';
  final incomplete = apis == null
      ? 'Only the curated notes were checked: the API lists are missing '
            '(${delta.missing}).'
      : null;
  final display = query.display;
  String headline(String verb, List<_Hit> list) {
    final hit = list.first;
    final text = _withFullStop(hit.text);
    final lead = hit.how == _How.container
        ? '`$display`: its class `${hit.name}` is $verb (${hit.library}): $text'
        : hit.name == display
        ? '`$display` is $verb: $text'
        : '`$display` is $verb in `${hit.name}` (${hit.library}): $text';
    return list.length > 1
        ? '$lead ${list.length - 1} more '
              '${list.length == 2 ? 'API matches' : 'APIs match'}; see '
              '`matches`.'
        : lead;
  }

  final summary = [
    ?incomplete,
    switch (status) {
      'removed' => headline('removed', removals),
      'deprecated' => headline('deprecated', deprecations),
      _ =>
        '`$display` is ok: nothing the project imports deprecates or '
            'removes it.',
    },
    if (status == 'ok' && rules.isNotEmpty)
      'Its deprecation forbids only this: ${rules.first}',
    if (status == 'ok' && parameters)
      'Some of its parameters are deprecated or removed; see `matches`.',
    if (notes > 0)
      '$notes curated ${notes == 1 ? 'note mentions' : 'notes mention'} it.',
  ].join(' ');
  return ToolReply({
    'name': display,
    'status': status,
    'matches': matches,
    if (status == 'ok')
      'meaning':
          'Nothing the project imports deprecates or removes `$display`. '
          "Whether it exists isn't checked here; the Dart MCP server's "
          'analyzer does that.',
    'incomplete': ?incomplete,
  }, summary);
}

/// Every API entry that matches [query], exactly or loosely.
List<_Hit> _collect(DeltaApis apis, _Query query) {
  final hits = <_Hit>[];
  for (final api in apis.deprecated) {
    final how = query.classify(api.name);
    if (how == null) continue;
    final status = how == _How.owner
        ? 'ok'
        : api.kind == 'use'
        ? 'deprecated'
        : 'ok';
    hits.add(
      _Hit(
        how: how,
        name: api.name,
        library: api.library,
        status: status,
        rule: api.kind == 'use' ? null : api.rule,
        text: api.message ?? 'deprecated, with no message',
        json: {
          'kind': 'deprecated',
          'library': api.library,
          'name': api.name,
          'deprecationKind': api.kind,
          'rule': ?api.rule,
          'message': ?api.message,
          if (api.migrations.isNotEmpty) 'migrations': api.migrations,
          if (how == _How.owner || how == _How.parameterName) 'parameter': true,
        },
      ),
    );
  }
  for (final api in apis.migrated) {
    final how = query.classify(api.name);
    if (how == null) continue;
    hits.add(
      _Hit(
        how: how,
        name: api.name,
        library: api.library,
        status: how != _How.owner && api.status == 'removed' ? 'removed' : 'ok',
        text: api.title,
        json: {
          'kind': api.status,
          'library': api.library,
          'name': api.name,
          'migration': api.title,
          if (how == _How.owner || how == _How.parameterName) 'parameter': true,
        },
      ),
    );
  }
  return hits;
}

/// The entries that deprecate or remove the class [container] itself, for a
/// query about one of its members. Another deprecation kind than `use`
/// forbids only that use, so it isn't listed.
List<_Hit> _classHits(DeltaApis apis, String container) {
  final hits = <_Hit>[];
  for (final api in apis.deprecated) {
    if (api.name != container || api.kind != 'use') continue;
    hits.add(
      _Hit(
        how: _How.container,
        name: api.name,
        library: api.library,
        status: 'deprecated',
        text: api.message ?? 'deprecated, with no message',
        json: {
          'kind': 'deprecated',
          'library': api.library,
          'name': api.name,
          'deprecationKind': api.kind,
          'message': ?api.message,
          if (api.migrations.isNotEmpty) 'migrations': api.migrations,
        },
      ),
    );
  }
  for (final api in apis.migrated) {
    if (api.name != container || api.status != 'removed') continue;
    hits.add(
      _Hit(
        how: _How.container,
        name: api.name,
        library: api.library,
        status: 'removed',
        text: api.title,
        json: {
          'kind': api.status,
          'library': api.library,
          'name': api.name,
          'migration': api.title,
        },
      ),
    );
  }
  return hits;
}

/// How an entry matches the query. [exact]: its name is the query's.
/// [loose]: the member's name matches, under another class or receiver.
/// [owner]: the query names the member that owns a deprecated parameter.
/// [parameterName]: the query is that parameter's name.
/// [container]: the query is a member of the class the entry deprecates or
/// removes.
enum _How { exact, loose, owner, parameterName, container }

final class _Hit {
  _Hit({
    required this.how,
    required this.name,
    required this.library,
    required this.status,
    required this.text,
    required this.json,
    this.rule,
  });

  final _How how;
  final String name;
  final String library;

  /// `removed`, `deprecated` or `ok`: what this entry does to the status.
  final String status;
  final String text;
  final String? rule;
  final Map<String, Object?> json;
}

final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// The first named argument of an argument list: `textScaleFactor: 1.2`.
final _namedArgument = RegExp(r'^([A-Za-z_$][A-Za-z0-9_$]*)\s*:(?!:)');

/// [text] without its `<...>` type arguments, nested ones included:
/// `Map<String, List<int>>.new` is `Map.new`.
String _withoutTypeArguments(String text) {
  final buffer = StringBuffer();
  var depth = 0;
  for (final unit in text.split('')) {
    if (unit == '<') {
      depth++;
    } else if (unit == '>' && depth > 0) {
      depth--;
    } else if (depth == 0) {
      buffer.write(unit);
    }
  }
  return buffer.toString();
}

/// A name as an agent writes it, taken apart for matching.
final class _Query {
  _Query._({
    required this.display,
    required this.heads,
    required this.parameter,
    required this.looseName,
    required this.bareParameter,
    required this.noteTerms,
    required this.uri,
    required this.container,
  });

  /// Parses what the agent wrote: an expression, a constructor, a name.
  factory _Query.parse(String raw) {
    var text = raw.trim();
    while (text.startsWith('.')) {
      text = text.substring(1).trim();
    }
    var head = text;
    String? parameter;
    var hasArguments = false;
    final open = text.indexOf('(');
    if (open >= 0) {
      hasArguments = true;
      head = text.substring(0, open).trim();
      final close = text.lastIndexOf(')');
      final arguments = text
          .substring(open + 1, close > open ? close : text.length)
          .trim();
      // `Text(textScaleFactor)` or `Text(textScaleFactor: 1.2)`.
      parameter = _identifier.hasMatch(arguments)
          ? arguments
          : _namedArgument.firstMatch(arguments)?.group(1);
    }
    head = _withoutTypeArguments(head).trim();
    if (head.endsWith('=')) head = head.substring(0, head.length - 1);
    final uri = head.contains(':') || head.contains('/');
    final segments = uri ? [head] : head.split('.');
    final last = segments.last;
    final owner = segments.length == 1 && _isUpper(head);
    // `Foo(...)` is the unnamed constructor `Foo.new` (or the class `Foo`).
    final constructor = hasArguments && owner;
    final heads = constructor ? ['$head.new', head] : [head];
    final display = parameter == null ? head : '$head($parameter)';
    return _Query._(
      display: display,
      heads: heads,
      parameter: parameter,
      looseName: uri || constructor || last == 'new' || last.isEmpty
          ? null
          : last,
      bareParameter: !uri && segments.length == 1 && !hasArguments
          ? head
          : null,
      noteTerms: {
        if (head.isNotEmpty) head,
        if (!uri && segments.length > 1 && last != 'new' && last.isNotEmpty)
          last,
      },
      uri: uri ? head : null,
      container: !uri && segments.length > 1 && segments.first.isNotEmpty
          ? segments.sublist(0, segments.length - 1).join('.')
          : null,
    );
  }

  /// The text to show: the query without its argument list.
  final String display;

  /// Names an entry's member part may equal for an exact match.
  final List<String> heads;

  /// The parameter named in `Owner.new(param)` or `Owner(param)`.
  final String? parameter;

  /// The member name a looser match compares, or null when none applies.
  final String? looseName;

  /// The query as a possible parameter name (`textScaleFactor`).
  final String? bareParameter;

  /// The identifiers a curated note's `avoid` text is searched for.
  final Set<String> noteTerms;

  /// The library URI, when the query is one.
  final String? uri;

  /// What owns the member, when the query has two or more segments: the part
  /// before the last one (`MaterialStateProperty` for `.all`, and for `.new`).
  final String? container;

  /// The same query without its parameter.
  _Query withoutParameter() =>
      _Query.parse(display.replaceFirst(RegExp(r'\([^)]*\)$'), ''));

  /// Whether a moved library's URI [from] is the one named: exactly, with
  /// `package:` left out, or by its trailing path (`material.dart`).
  bool namesLibrary(String from) {
    final uri = this.uri;
    if (uri == null) return false;
    if (from == uri || from == 'package:$uri') return true;
    return !uri.startsWith('package:') && from.endsWith('/$uri');
  }

  /// How the delta entry [entry] matches, or null.
  _How? classify(String entry) {
    var member = entry;
    String? entryParameter;
    final paren = entry.indexOf('(');
    if (paren >= 0) {
      member = entry.substring(0, paren);
      entryParameter = entry.substring(paren + 1, entry.length - 1);
    }
    if (member.endsWith('=')) member = member.substring(0, member.length - 1);
    final entryName = member.split('.').last;
    if (entryParameter == null) {
      if (heads.contains(member)) return _How.exact;
      if (looseName != null && entryName == looseName) return _How.loose;
      return null;
    }
    if (parameter != null) {
      return heads.contains(member) && entryParameter == parameter
          ? _How.exact
          : null;
    }
    if (heads.contains(member)) return _How.owner;
    if (looseName != null && entryName == looseName) return _How.owner;
    if (bareParameter != null && entryParameter == bareParameter) {
      return _How.parameterName;
    }
    return null;
  }
}

bool _isUpper(String text) =>
    text.isNotEmpty && text[0] != text[0].toLowerCase();

/// Whether [text] has [term] as a whole word: not inside a longer name.
bool _namesWord(String text, String term) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(term)}(?![A-Za-z0-9_])',
).hasMatch(text);

String _withFullStop(String text) {
  final trimmed = text.trim();
  return trimmed.endsWith('.') ? trimmed : '$trimmed.';
}
