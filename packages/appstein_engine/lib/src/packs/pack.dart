import 'package:appstein_protocol/appstein_protocol.dart';

import '../map/map_extractor.dart';
import '../native/native_extractor.dart';

/// Whether a pack describes how an app is built (its architecture) or a
/// platform it runs on (spec §10).
enum PackKind {
  /// An app architecture, such as `official_mvvm`.
  stack,

  /// A target platform, such as `android`.
  platform,
}

/// A pack (spec §10). Packs contribute what is specific to one stack or
/// platform; the engine core never imports one (§5.1), so the CLI hands
/// them in.
///
/// The interface grows with the slices: each member is added in the slice
/// that first uses it.
abstract interface class Pack {
  /// The pack's id, such as `official_mvvm`.
  String get id;

  /// Whether it is a stack or a platform pack.
  PackKind get kind;

  /// The pack's version. It is part of the map's input hash, so a new pack
  /// rebuilds the map.
  String get version;

  /// What it adds to `.appstein/map/`.
  List<MapExtractor> get extractors;

  /// What it adds to `map/native.json` (spec §6.5); null for a stack pack.
  /// Platform packs arrive in slice 1b.4.
  NativeExtractor? get nativeExtractor;

  /// The layer rules a stack pack declares (spec §9.6), or null.
  LayerRules? get layerRules;
}
