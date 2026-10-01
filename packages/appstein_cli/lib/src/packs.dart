import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// The packs a project's `appstein.yaml` names (spec §7, §10). The CLI
/// chooses them because the engine core never imports a pack (§5.1).
///
/// The config loader accepts only known stacks, so every stack here has a
/// pack. Platform packs arrive with the native map (slice 1b.4).
List<Pack> packsFor(AppsteinConfig config) => switch (config.packs.stack) {
  'official_mvvm' => const [OfficialMvvmPack()],
  final stack => throw StateError('No pack for the stack "$stack".'),
};
