import 'package:appstein_protocol/src/json_fields.dart';
import 'package:test/test.dart';

void main() {
  const fields = JsonFields('x.json', {
    'name': 'a',
    'count': 3,
    'none': null,
    'inner': {'k': 'v'},
    'items': [
      {'k': 1},
    ],
    'strings': {'a': 'b'},
    'mixed': {'a': 1},
  });

  test('reads typed fields', () {
    expect(fields.string('name'), 'a');
    expect(fields.integer('count'), 3);
    expect(fields.optionalString('none'), isNull);
    expect(fields.optionalString('missing'), isNull);
    expect(fields.object('inner').string('k'), 'v');
    expect(fields.optionalObject('none'), isNull);
    expect(fields.objects('items').single.integer('k'), 1);
    expect(fields.stringMap('strings'), {'a': 'b'});
  });

  test('a wrong or missing field names the file and key', () {
    expect(
      () => fields.string('count'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'x.json: "count" must be a string.',
        ),
      ),
    );
    expect(() => fields.integer('missing'), throwsFormatException);
    expect(() => fields.object('name'), throwsFormatException);
    expect(() => fields.objects('inner'), throwsFormatException);
    expect(() => fields.stringMap('mixed'), throwsFormatException);
    expect(() => fields.optionalString('count'), throwsFormatException);
  });
}
