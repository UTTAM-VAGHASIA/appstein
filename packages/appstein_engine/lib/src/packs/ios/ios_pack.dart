import 'package:appstein_protocol/appstein_protocol.dart';

import '../../docs/doc_page.dart';
import '../../map/map_extractor.dart';
import '../../native/native_extractor.dart';
import '../pack.dart';
import 'ios_docs.dart';
import 'ios_native.dart';

/// The ios platform pack (spec §10): iOS's part of `map/native.json`. Its
/// checks arrive with the verifier (slice 1d).
final class IosPack implements Pack {
  /// Creates the pack.
  const IosPack();

  @override
  String get id => 'ios';

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '2';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor get nativeExtractor => const IosNativeExtractor();

  @override
  List<DocPage> get docPages => const [IosDocs()];
}

/// Writes the `ios` section of `map/native.json`.
final class IosNativeExtractor implements NativeExtractor {
  /// Creates the extractor.
  const IosNativeExtractor();

  @override
  String get section => 'ios';

  @override
  NativeSection extract(NativeContext context) => readIosNative(context);
}
