import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// The packs a project's `appstein.yaml` names (spec §7, §10): its stack
/// pack, then one pack per platform. The CLI chooses them because the
/// engine core never imports a pack (§5.1).
///
/// The config loader accepts only known stacks and platforms, each platform
/// once, so each has a pack.
List<Pack> packsFor(AppsteinConfig config) => [
  switch (config.packs.stack) {
    'official_mvvm' => const OfficialMvvmPack(),
    final stack => throw StateError('No pack for the stack "$stack".'),
  },
  for (final platform in config.packs.platforms)
    switch (platform) {
      'android' => const AndroidPack(),
      'ios' => const IosPack(),
      final other => throw StateError('No pack for the platform "$other".'),
    },
];
