import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('every stack the config loader accepts has a pack', () {
    for (final stack in knownStacks) {
      final config = AppsteinConfig(packs: PacksConfig(stack: stack));
      expect(packsFor(config), isNotEmpty, reason: stack);
    }
  });

  test('every platform the config loader accepts has a pack', () {
    for (final platform in knownPlatforms) {
      final config = AppsteinConfig(packs: PacksConfig(platforms: [platform]));
      expect([
        for (final pack in packsFor(config)) pack.id,
      ], contains(platform));
    }
  });

  test('the default config gives the stack pack, then both platform packs', () {
    expect(
      [for (final pack in packsFor(const AppsteinConfig())) pack.id],
      ['official_mvvm', 'android', 'ios'],
    );
  });
}
