import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('withoutNulls drops null values and list items, at any depth', () {
    expect(
      withoutNulls({
        'a': null,
        'b': 1,
        'c': {'d': null, 'e': 'x'},
        'f': [
          null,
          2,
          {'g': null},
        ],
      }),
      {
        'b': 1,
        'c': {'e': 'x'},
        'f': [2, <String, Object?>{}],
      },
    );
  });

  test('toolOutputSchema adds summary and freshness as required', () {
    final schema = toolOutputSchema(
      jsonObject({'index': jsonString()}, required: ['index']),
    );
    expect((schema['properties']! as Map).keys, [
      'index',
      'summary',
      'freshness',
    ]);
    expect(schema['required'], ['index', 'summary', 'freshness']);
    expect(schema['type'], 'object');
  });
}
