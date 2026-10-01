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
}
