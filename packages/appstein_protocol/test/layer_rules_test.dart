import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final valid = {
    'layers': {
      'ui': ['lib/ui/**'],
      'domain': ['lib/domain/**'],
      'data.repository': ['lib/data/repositories/**'],
    },
    'allow': {
      'ui': ['domain'],
      'domain': <String>[],
    },
  };

  test('parses a valid section and keeps declaration order', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.layers.keys, ['ui', 'domain', 'data.repository']);
    expect(rules.allow['ui'], ['domain']);
  });

  test('a layer may import itself and its allowed layers', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.mayImport('ui', 'ui'), isTrue);
    expect(rules.mayImport('ui', 'domain'), isTrue);
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(rules.mayImport('domain', 'ui'), isFalse);
  });

  test('a layer without an allow entry is unrestricted', () {
    final rules = LayerRules.fromJson(valid);
    expect(rules.mayImport('data.repository', 'ui'), isTrue);
  });

  test('round-trips through JSON', () {
    final rules = LayerRules.fromJson(valid);
    expect(LayerRules.fromJson(rules.toJson()).toJson(), rules.toJson());
  });

  test('rejects an unknown key', () {
    expect(
      () =>
          LayerRules.fromJson(<String, Object?>{'layer': <String, Object?>{}}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unknown key "layer"'),
        ),
      ),
    );
  });

  test('rejects an allow entry for an undeclared tag', () {
    expect(
      () => LayerRules.fromJson({
        'layers': {
          'ui': ['lib/ui/**'],
        },
        'allow': {
          'ui': ['data'],
        },
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('"data"'),
        ),
      ),
    );
  });

  test('rejects a tag with capitals or spaces', () {
    expect(
      () => LayerRules.fromJson({
        'layers': {
          'Data Layer': ['lib/data/**'],
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a layer with no globs or a non-list value', () {
    expect(
      () => LayerRules.fromJson({
        'layers': {'ui': <String>[]},
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayerRules.fromJson({
        'layers': {'ui': 'lib/ui/**'},
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('a non-map section is a FormatException', () {
    expect(() => LayerRules.fromJson(['ui']), throwsA(isA<FormatException>()));
  });

  final withInterfaces = {
    ...valid,
    'interfaces': {
      'ui': ['data.repository'],
    },
  };

  test('a layer may import interface files of the tags under its '
      'interfaces', () {
    final rules = LayerRules.fromJson(withInterfaces);
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(
      rules.mayImport('ui', 'data.repository', interfaceOnly: true),
      isTrue,
    );
    expect(
      rules.mayImport('domain', 'data.repository', interfaceOnly: true),
      isFalse,
    );
  });

  test('describes what a layer may import', () {
    final rules = LayerRules.fromJson(withInterfaces);
    expect(
      rules.describeAllowed('ui'),
      'ui, domain, and the interfaces of data.repository',
    );
    expect(rules.describeAllowed('domain'), 'domain');
    expect(rules.describeAllowed('data.repository'), 'any layer');
  });

  test('rejects an interfaces entry that names an undeclared tag', () {
    expect(
      () => LayerRules.fromJson({
        ...valid,
        'interfaces': {
          'ui': ['nowhere'],
        },
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'interfaces: "ui" lists "nowhere", which is not declared under '
              'layers.',
        ),
      ),
    );
  });

  test('toJson leaves out an empty interfaces section', () {
    expect(
      LayerRules.fromJson(valid).toJson().containsKey('interfaces'),
      isFalse,
    );
    expect(LayerRules.fromJson(withInterfaces).toJson()['interfaces'], {
      'ui': ['data.repository'],
    });
  });

  test('the unknown-key message lists interfaces', () {
    expect(
      () =>
          LayerRules.fromJson(<String, Object?>{'layer': <String, Object?>{}}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Allowed: layers, allow, interfaces.'),
        ),
      ),
    );
  });
}
