import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;

  test('writes the marker as one HTML comment', () {
    expect(
      DocMarker(templates: const {'engine': '1'}, inputs: a, body: b).line,
      '<!-- appstein:generated templates=engine@1 inputs=$a body=$b -->',
    );
    expect(
      DocMarker(
        templates: const {'android': '3', 'ios': '2'},
        inputs: a,
        body: b,
      ).line,
      '<!-- appstein:generated templates=android@3,ios@2 inputs=$a body=$b -->',
    );
  });

  test('reads its own line back', () {
    for (final templates in [
      {'engine': '1'},
      {'android': '3', 'ios': '2'},
    ]) {
      final marker = DocMarker(templates: templates, inputs: a, body: b);
      final read = DocMarker.of('${marker.line}\n# Title\n')!;
      expect(read.templates, templates);
      expect(read.templates.keys, templates.keys);
      expect(read.inputs, a);
      expect(read.body, b);
    }
  });

  test('reads a marker after a BOM and before a carriage return', () {
    final marker = DocMarker(
      templates: const {'engine': '1'},
      inputs: a,
      body: b,
    );
    final bom = String.fromCharCode(0xFEFF);
    expect(DocMarker.of('$bom${marker.line}\r\n# T\r\n')?.body, b);
    expect(DocMarker.of(marker.line)?.inputs, a);
  });

  test('finds no marker where there is none', () {
    final line = DocMarker(
      templates: const {'engine': '1'},
      inputs: a,
      body: b,
    ).line;
    expect(DocMarker.of(''), isNull);
    expect(DocMarker.of('# Title\n'), isNull);
    expect(DocMarker.of('\n$line\n'), isNull, reason: 'on line 2');
    expect(DocMarker.of(' $line\n'), isNull, reason: 'indented');
    expect(
      DocMarker.of('<!-- appstein:generated templates=engine@1 inputs=$a -->'),
      isNull,
      reason: 'no body',
    );
    expect(
      DocMarker.of('<!-- appstein:generated templates= inputs=$a body=$b -->'),
      isNull,
      reason: 'no templates',
    );
    expect(
      DocMarker.of(
        '<!-- appstein:generated templates=engine@1 inputs=xyz body=$b -->',
      ),
      isNull,
      reason: 'a hash that is not one',
    );
    expect(DocMarker.of('$line trailing'), isNull);
  });

  test('a page is its marker line, then its body', () {
    final marker = DocMarker(
      templates: const {'engine': '1'},
      inputs: a,
      body: b,
    );
    expect(markedPage(marker, '# T\n'), '${marker.line}\n# T\n');
  });

  test('the body is everything after the first line, with plain line ends', () {
    expect(bodyOf('<!-- x -->\n# T\n\ntext\n'), '# T\n\ntext\n');
    expect(bodyOf('<!-- x -->\r\n# T\r\ntext\r\n'), '# T\ntext\n');
    expect(bodyOf('<!-- x -->\r# T\rtext'), '# T\ntext');
    expect(bodyOf('<!-- x -->'), '');
  });

  test('the body hash ignores the kind of line ending', () {
    expect(bodyHash('a\r\nb\n'), bodyHash('a\nb\n'));
    expect(bodyHash('a\rb\n'), bodyHash('a\nb\n'));
    expect(bodyHash('a\nb\n'), isNot(bodyHash('a\nb')));
    expect(bodyHash('a\n'), hasLength(64));
  });

  test('plainLines drops a BOM and carriage returns', () {
    final bom = String.fromCharCode(0xFEFF);
    expect(plainLines('${bom}a\r\nb\rc\n'), 'a\nb\nc\n');
  });
}
