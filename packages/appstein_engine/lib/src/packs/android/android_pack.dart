import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/map_extractor.dart';
import '../../native/native_extractor.dart';
import '../pack.dart';
import 'android_native.dart';

/// The android platform pack (spec §10): Android's part of
/// `map/native.json`. Its checks arrive with the verifier (slice 1d).
final class AndroidPack implements Pack {
  /// Creates the pack.
  const AndroidPack();

  @override
  String get id => 'android';

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor get nativeExtractor => const AndroidNativeExtractor();
}

/// Writes the `android` section of `map/native.json`.
final class AndroidNativeExtractor implements NativeExtractor {
  /// Creates the extractor.
  const AndroidNativeExtractor();

  @override
  String get section => 'android';

  @override
  NativeSection extract(NativeContext context) => readAndroidNative(context);
}
