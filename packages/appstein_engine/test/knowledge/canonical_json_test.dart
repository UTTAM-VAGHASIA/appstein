import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test(
    'sorts keys at every level, indents two spaces, ends with a newline',
    () {
      expect(
        canonicalJson({
          'b': 1,
          'a': {
            'd': [
              {'z': 1, 'y': 2},
            ],
            'c': null,
          },
        }),
        '{\n'
        '  "a": {\n'
        '    "c": null,\n'
        '    "d": [\n'
        '      {\n'
        '        "y": 2,\n'
        '        "z": 1\n'
        '      }\n'
        '    ]\n'
        '  },\n'
        '  "b": 1\n'
        '}\n',
      );
    },
  );

  test('the same value gives the same text whatever the insertion order', () {
    expect(canonicalJson({'x': 1, 'y': 2}), canonicalJson({'y': 2, 'x': 1}));
  });

  test('keeps list order and writes non-ASCII text as is', () {
    expect(canonicalJson(['b', 'a']), '[\n  "b",\n  "a"\n]\n');
    expect(canonicalJson({'path': r'C:\Jöhn Doe'}), contains('Jöhn Doe'));
  });
}
