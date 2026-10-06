import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  test('the pack describes itself', () {
    const pack = OfficialMvvmPack();
    expect(pack.id, 'official_mvvm');
    expect(pack.kind, PackKind.stack);
    // 2: routes.json gained `redirectTo` (slice 1c.5). The version is part
    // of the map's input hash, so raising it rebuilds every project's map.
    expect(pack.version, '2');
    expect(pack.layerRules, same(officialMvvmLayerRules));
    expect(pack.extractors, hasLength(1));
  });

  test('its layer rules are valid and follow spec §9.6', () {
    final rules = LayerRules.fromJson(officialMvvmLayerRules.toJson());
    expect(rules.layers.keys, [
      'test',
      'ui',
      'data.repository',
      'data.service',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ]);
    // ui reaches data only through interfaces.
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(
      rules.mayImport('ui', 'data.repository', interfaceOnly: true),
      isTrue,
    );
    expect(rules.mayImport('ui', 'data.service', interfaceOnly: true), isTrue);
    expect(rules.mayImport('ui', 'routing'), isTrue);
    // Use cases in domain call repositories through their interfaces.
    expect(
      rules.mayImport('domain', 'data.repository', interfaceOnly: true),
      isTrue,
    );
    expect(
      rules.mayImport('domain', 'data.service', interfaceOnly: true),
      isFalse,
    );
    expect(rules.mayImport('domain', 'ui'), isFalse);
    // data.* may import anything but ui.
    for (final data in ['data.repository', 'data.service', 'data.model']) {
      for (final tag in rules.layers.keys) {
        expect(rules.mayImport(data, tag), tag != 'ui', reason: '$data → $tag');
      }
    }
    // routing, config, utils and tests are unrestricted.
    for (final free in ['routing', 'config', 'utils', 'test']) {
      expect(rules.mayImport(free, 'ui'), isTrue, reason: free);
    }
  });

  test('the extractor writes features.json and routes.json', () async {
    final analysis = await ProjectAnalysis.analyze(
      copyFixtureApp(),
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final files = const OfficialMvvmPack().extractors.single.extract(analysis);
    expect(files.keys.toSet(), {MapFiles.features, MapFiles.routes});
    expect(
      FeaturesMap.fromJson(files[MapFiles.features]!).features.keys,
      containsAll(['home', 'booking', 'auth/login']),
    );
    expect(RoutesMap.fromJson(files[MapFiles.routes]!).routes, hasLength(8));
  });
}
