import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final symbols = SymbolsMap.fromJson(golden('symbols.json'));
  final routes = RoutesMap.fromJson(golden('routes.json'));
  final features = FeaturesMap.fromJson(golden('features.json'));
  final layers = LayersMap.fromJson(golden('layers.json'));

  ToolAnswer ask(String query) => whereIs(
    query,
    symbols: symbols,
    routes: routes,
    features: features,
    layers: layers,
  );

  List<Map<String, Object?>> matches(String query) =>
      ((ask(query) as ToolReply).result['matches']! as List)
          .cast<Map<String, Object?>>();

  test('searchWords splits camelCase, snake_case and paths', () {
    expect(searchWords('LoginScreen'), ['login', 'screen']);
    expect(searchWords('login_screen'), ['login', 'screen']);
    expect(searchWords('lib/ui/auth/login/widgets/login_screen.dart'), [
      'lib',
      'ui',
      'auth',
      'login',
      'widgets',
      'login',
      'screen',
      'dart',
    ]);
    expect(searchWords('HTTPClient'), ['http', 'client']);
    expect(searchWords('/booking/:id'), ['booking', 'id']);
  });

  test('"login screen": the symbol first, then the route, with reasons', () {
    final found = matches('login screen');
    expect(found.first, containsPair('kind', 'symbol'));
    expect(found.first, containsPair('name', 'LoginScreen'));
    expect(found.first['score'], 10);
    expect(found.first['file'], 'lib/ui/auth/login/widgets/login_screen.dart');
    expect(found.first['feature'], 'auth/login');
    expect(found.first['layer'], 'ui');
    expect(found.first['reasons'], [
      '`login` is a word of the symbol name `LoginScreen`',
      '`screen` is a word of the symbol name `LoginScreen`',
    ]);
    expect(found[1], containsPair('kind', 'route'));
    expect(found[1], containsPair('name', '/login'));
    expect(found[1]['score'], 8);
  });

  test('scores tiers: symbol 5 > route 4 > feature 3 > path 2', () {
    // "settings" has few matches, so every kind's match is listed.
    final found = matches('settings');
    int score(String kind, String name) =>
        found.firstWhere(
              (m) => m['kind'] == kind && m['name'] == name,
            )['score']!
            as int;
    expect(score('symbol', 'SettingsScreen'), 5);
    expect(score('route', '/settings'), 4);
    expect(score('feature', 'settings'), 3);
    expect(score('file', 'lib/ui/settings/widgets/settings_screen.dart'), 2);
  });

  test('a typo of four or more letters matches within two edits, for 1', () {
    final found = matches('bookng');
    expect(found, isNotEmpty);
    expect(found.every((m) => m['score'] == 1), isTrue);
    expect(
      (found.first['reasons']! as List).single,
      contains('`bookng` is close to `booking`'),
    );
  });

  test('ties go to the name, then the file, and at most 10 are listed', () {
    final reply = ask('screen') as ToolReply;
    final found = (reply.result['matches']! as List)
        .cast<Map<String, Object?>>();
    expect(found.length, whereIsLimit);
    expect(reply.result['total'], greaterThan(whereIsLimit));
    final symbolsFound = [
      for (final m in found)
        if (m['kind'] == 'symbol') m['name'],
    ];
    expect(symbolsFound, [...symbolsFound]..sort());
  });

  test('a word in ten or more symbol names still shows the best feature, '
      'route and file', () {
    final reply = ask('booking') as ToolReply;
    final found = (reply.result['matches']! as List)
        .cast<Map<String, Object?>>();
    expect(found.length, whereIsLimit);
    int count(String kind) => found.where((m) => m['kind'] == kind).length;
    expect(count('feature'), 1);
    expect(count('route'), 1);
    expect(count('file'), 1);
    expect(count('symbol'), whereIsLimit - 3);
    expect(
      found.firstWhere((m) => m['kind'] == 'feature'),
      containsPair('name', 'booking'),
    );
    final scores = [for (final m in found) m['score']! as int];
    expect(scores, [...scores]..sort((a, b) => b.compareTo(a)));
  });

  test('a best-of-kind match already in the top ten is listed once', () {
    final found = matches('login screen');
    final keys = [for (final m in found) '${m['kind']} ${m['name']}'];
    expect(keys.toSet().length, keys.length);
    expect(found.length, whereIsLimit);
  });

  test('fewer than ten matches are each listed once', () {
    final reply = ask('profile') as ToolReply;
    final found = (reply.result['matches']! as List)
        .cast<Map<String, Object?>>();
    expect(reply.result['total'], lessThan(whereIsLimit));
    expect(found.length, reply.result['total']);
    final keys = [for (final m in found) '${m['kind']} ${m['name']}'];
    expect(keys.toSet().length, keys.length);
  });

  test('a typo match needs four letters on both sides', () {
    Iterable<String> reasons(String query) => [
      for (final m in matches(query)) ...(m['reasons']! as List).cast<String>(),
    ];
    expect(reasons('list').where((r) => r.contains('close to `lib`')), isEmpty);
    expect(reasons('list').where((r) => r.contains('close to `ui`')), isEmpty);
    expect(reasons('logn'), contains(contains('`logn` is close to `login`')));
  });

  test('nothing matched is a reply with no matches', () {
    final reply = ask('zebra') as ToolReply;
    expect(reply.result['matches'], isEmpty);
    expect(reply.summary, 'Nothing in the project map matches "zebra".');
  });

  test('a query with no letters or digits is refused', () {
    expect(
      (ask('!!!') as ToolRefusal).message,
      'The query "!!!" has no letters or digits to match.',
    );
  });

  test('the result matches its schema', () {
    final reply = ask('login screen') as ToolReply;
    expectMatchesSchema(ToolSchemas.whereIsResult, withoutNulls(reply.result));
  });
}
