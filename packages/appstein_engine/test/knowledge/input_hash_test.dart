import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('sha256Hex is lowercase hex SHA-256', () {
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  group('inputHash', () {
    String hash(
      Map<String, List<int>?> inputs, {
      String appstein = '0.1.0',
      int format = 1,
    }) => inputHash(inputs, appsteinVersion: appstein, formatVersion: format);

    final a = utf8.encode('a');
    final b = utf8.encode('b');

    test('does not depend on the order of the inputs', () {
      expect(hash({'x': a, 'y': b}), hash({'y': b, 'x': a}));
    });

    test('changes when an input, its name, or its presence changes', () {
      final base = hash({'x': a});
      expect(hash({'x': b}), isNot(base));
      expect(hash({'z': a}), isNot(base));
      expect(hash({'x': null}), isNot(base));
      expect(hash({'x': a, 'y': null}), isNot(base));
    });

    test('changes with the Appstein or format version', () {
      final base = hash({'x': a});
      expect(hash({'x': a}, appstein: '0.2.0'), isNot(base));
      expect(hash({'x': a}, format: 2), isNot(base));
    });
  });
}
