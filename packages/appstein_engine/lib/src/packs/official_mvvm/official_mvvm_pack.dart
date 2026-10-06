import 'package:appstein_protocol/appstein_protocol.dart';

import '../../docs/doc_page.dart';
import '../../map/map_extractor.dart';
import '../../map/project_analysis.dart';
import '../../native/native_extractor.dart';
import '../pack.dart';
import 'docs/architecture_page.dart';
import 'docs/feature_pages.dart';
import 'docs/routes_page.dart';
import 'features.dart';
import 'layer_rules.dart';
import 'routes.dart';

/// The official_mvvm stack pack (spec §10): Flutter's recommended app
/// architecture, as in its compass_app sample.
final class OfficialMvvmPack implements Pack {
  /// Creates the pack.
  const OfficialMvvmPack();

  @override
  String get id => 'official_mvvm';

  @override
  PackKind get kind => PackKind.stack;

  @override
  String get version => '3';

  @override
  List<MapExtractor> get extractors => const [OfficialMvvmExtractor()];

  @override
  LayerRules get layerRules => officialMvvmLayerRules;

  @override
  NativeExtractor? get nativeExtractor => null;

  @override
  List<DocPage> get docPages => const [
    ArchitecturePage(),
    FeaturePages(),
    RoutesPage(),
  ];
}

/// Writes official_mvvm's part of the map: `routes.json` and
/// `features.json`, whose screens come from the routes.
final class OfficialMvvmExtractor implements MapExtractor {
  /// Creates the extractor.
  const OfficialMvvmExtractor();

  @override
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis) {
    final routes = readRoutes(analysis);
    final features = readFeatures(
      analysis,
      routes: routes,
      matcher: LayerMatcher(officialMvvmLayerRules),
    );
    return {
      MapFiles.routes: routes.toJson(),
      MapFiles.features: features.toJson(),
    };
  }
}
