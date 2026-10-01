import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('the map files live under map/', () {
    expect(MapFiles.all, [
      'map/deps.json',
      'map/features.json',
      'map/layers.json',
      'map/routes.json',
      'map/symbols.json',
    ]);
  });

  test('symbols round-trip, with null summaries kept', () {
    const map = SymbolsMap(
      symbols: [
        MapSymbol(
          name: 'HomeViewModel',
          kind: SymbolKind.classKind,
          file: 'lib/ui/home/view_models/home_viewmodel.dart',
          line: 7,
          layer: 'ui',
          feature: 'home',
          summary: "Loads the user's bookings for the home screen.",
        ),
        MapSymbol(
          name: 'Json',
          kind: SymbolKind.typedef,
          file: 'lib/utils/result.dart',
          line: 3,
        ),
      ],
    );
    final json = map.toJson();
    expect((json['symbols']! as List).first, {
      'name': 'HomeViewModel',
      'kind': 'class',
      'file': 'lib/ui/home/view_models/home_viewmodel.dart',
      'line': 7,
      'layer': 'ui',
      'feature': 'home',
      'summary': "Loads the user's bookings for the home screen.",
    });
    expect((json['symbols']! as List).last, containsPair('summary', null));
    expect(SymbolsMap.fromJson({...json, 'meta': {}}).toJson(), json);
  });

  test('every symbol kind has its JSON name', () {
    expect(SymbolKind.values.map((k) => k.jsonName), [
      'class',
      'mixin',
      'enum',
      'extension',
      'extensionType',
      'typedef',
      'function',
    ]);
  });

  test('an unknown symbol kind is a FormatException naming the file', () {
    expect(
      () => SymbolsMap.fromJson({
        'symbols': [
          {'name': 'A', 'kind': 'struct', 'file': 'lib/a.dart', 'line': 1},
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'symbols.json: unknown symbol kind "struct".',
        ),
      ),
    );
  });

  test('layers round-trip', () {
    const map = LayersMap(
      files: {
        'lib/ui/a.dart': MapFileEntry(
          layer: 'ui',
          feature: 'a',
          imports: ['lib/data/b.dart'],
        ),
        'lib/main.dart': MapFileEntry(imports: []),
      },
      violations: [
        LayerViolation(
          file: 'lib/ui/a.dart',
          line: 3,
          import: 'lib/data/b.dart',
          from: 'ui',
          to: 'data.repository',
        ),
      ],
    );
    final json = map.toJson();
    expect(
      json['files'],
      containsPair('lib/main.dart', {
        'layer': null,
        'feature': null,
        'imports': <String>[],
      }),
    );
    expect(LayersMap.fromJson(json).toJson(), json);
  });

  test('deps round-trip', () {
    const map = DepsMap(
      packages: {
        'go_router': PackageDependency(
          constraint: '^18.0.0',
          version: '18.0.2',
          dependency: 'direct main',
          source: 'hosted',
          usages: ['lib/routing/router.dart'],
        ),
        'collection': PackageDependency(
          version: '1.19.1',
          dependency: 'transitive',
          source: 'hosted',
          usages: [],
        ),
      },
    );
    final json = map.toJson();
    expect(
      json['packages'],
      containsPair('collection', {
        'constraint': null,
        'version': '1.19.1',
        'dependency': 'transitive',
        'source': 'hosted',
        'usages': <String>[],
      }),
    );
    expect(DepsMap.fromJson(json).toJson(), json);
  });

  test('features round-trip, and featureOf finds files and tests', () {
    const map = FeaturesMap(
      features: {
        'home': Feature(
          folder: 'lib/ui/home',
          viewModels: [
            CodeRef(
              name: 'HomeViewModel',
              file: 'lib/ui/home/view_models/h.dart',
            ),
          ],
          screens: [],
          repositories: [],
          services: [],
          models: [],
          tests: ['test/ui/home/h_test.dart'],
          files: ['lib/ui/home/view_models/h.dart'],
        ),
      },
    );
    final json = map.toJson();
    expect(FeaturesMap.fromJson(json).toJson(), json);
    expect(map.featureOf('lib/ui/home/view_models/h.dart'), 'home');
    expect(map.featureOf('test/ui/home/h_test.dart'), 'home');
    expect(map.featureOf('lib/main.dart'), isNull);
  });

  test('routes round-trip, resolved and unresolved', () {
    const map = RoutesMap(
      routes: [
        MapRoute(
          path: '/booking',
          screen: CodeRef(
            name: 'BookingScreen',
            file: 'lib/ui/booking/widgets/b.dart',
          ),
          parent: '/',
          file: 'lib/routing/router.dart',
          line: 40,
        ),
        MapRoute(
          file: 'lib/routing/router.dart',
          line: 50,
          parent: '/',
          unresolved: true,
          reason: 'the path is not a constant string',
        ),
      ],
      routers: [
        MapRouter(file: 'lib/routing/router.dart', line: 20, redirect: true),
      ],
    );
    final json = map.toJson();
    expect((json['routes']! as List).last, {
      'path': null,
      'name': null,
      'screen': null,
      'parent': '/',
      'redirect': false,
      'file': 'lib/routing/router.dart',
      'line': 50,
      'unresolved': true,
      'reason': 'the path is not a constant string',
    });
    expect(RoutesMap.fromJson(json).toJson(), json);
  });
}
