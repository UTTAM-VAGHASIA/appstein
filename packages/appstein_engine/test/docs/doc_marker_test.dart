import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  final b = 'b' * 64;

  test('writes the marker as one HTML comment', () {
    expect(
      DocMarker(templates: const {'engine': '1'}, body: b).line,
      '<!-- appstein:generated templates=engine@1 body=$b -->',
    );
    expect(
      DocMarker(templates: const {'android': '3', 'ios': '2'}, body: b).line,
      '<!-- appstein:generated templates=android@3,ios@2 body=$b -->',
    );
  });

  test('reads its own line back', () {
    for (final templates in [
      {'engine': '1'},
      {'android': '3', 'ios': '2'},
    ]) {
      final marker = DocMarker(templates: templates, body: b);
      final read = DocMarker.of('${marker.line}\n# Title\n')!;
      expect(read.templates, templates);
      expect(read.templates.keys, templates.keys);
      expect(read.body, b);
    }
  });

  test('reads a marker after a BOM and before a carriage return', () {
    final marker = DocMarker(templates: const {'engine': '1'}, body: b);
    final bom = String.fromCharCode(0xFEFF);
    expect(DocMarker.of('$bom${marker.line}\r\n# T\r\n')?.body, b);
    expect(DocMarker.of(marker.line)?.body, b);
  });

  test('finds no marker where there is none', () {
    final line = DocMarker(templates: const {'engine': '1'}, body: b).line;
    expect(DocMarker.of(''), isNull);
    expect(DocMarker.of('# Title\n'), isNull);
    expect(DocMarker.of('\n$line\n'), isNull, reason: 'on line 2');
    expect(DocMarker.of(' $line\n'), isNull, reason: 'indented');
    expect(
      DocMarker.of('<!-- appstein:generated templates=engine@1 -->'),
      isNull,
      reason: 'no body',
    );
    expect(
      DocMarker.of('<!-- appstein:generated templates= body=$b -->'),
      isNull,
      reason: 'no templates',
    );
    expect(
      DocMarker.of('<!-- appstein:generated templates=engine body=$b -->'),
      isNull,
      reason: 'a template without a version',
    );
    expect(
      DocMarker.of('<!-- appstein:generated templates=engine@1 body=xyz -->'),
      isNull,
      reason: 'a hash that is not one',
    );
    expect(DocMarker.of('$line trailing'), isNull);
  });

  test('a page is its marker line, then its body', () {
    final marker = DocMarker(templates: const {'engine': '1'}, body: b);
    expect(markedPage(marker, '# T\n'), '${marker.line}\n# T\n');
  });

  test('the body is everything after the first line, with plain line ends', () {
    expect(bodyOf('<!-- x -->\n# T\n\ntext\n'), '# T\n\ntext\n');
    expect(bodyOf('<!-- x -->\r\n# T\r\ntext\r\n'), '# T\ntext\n');
    expect(bodyOf('<!-- x -->'), '');
  });

  test('the body ends in one line break, whatever the file ends in', () {
    expect(bodyOf('<!-- x -->\r# T\rtext'), '# T\ntext\n');
    expect(bodyOf('<!-- x -->\n# T\ntext\n\n\n'), '# T\ntext\n');
    expect(bodyOf('<!-- x -->\n\n\n'), '');
    expect(bodyOf('<!-- x -->\n\n# T\n'), '\n# T\n');
  });

  test('withoutEndingBreaks drops only what an editor adds or strips', () {
    expect(withoutEndingBreaks('a\r\nb\r\n\r\n'), 'a\nb');
    expect(withoutEndingBreaks('a\n\nb'), 'a\n\nb');
    expect(withoutEndingBreaks('a \n'), 'a ');
    expect(withoutEndingBreaks(''), '');
  });

  group('isLeftoverPageWrite: only what a write of a page can leave', () {
    const body = '> note\n\n# Routes\n\nOne route.\n';
    final page = markedPage(
      DocMarker(templates: const {'engine': '2'}, body: bodyHash(body)),
      body,
    );

    test('an empty file', () {
      expect(isLeftoverPageWrite('', writing: page), isTrue);
    });

    test('a whole page nobody edited, of any render', () {
      expect(isLeftoverPageWrite(page, writing: 'another page'), isTrue);
      expect(
        isLeftoverPageWrite(page.replaceAll('\n', '\r\n'), writing: 'x'),
        isTrue,
      );
    });

    test('a write of this page that was cut short', () {
      expect(isLeftoverPageWrite(page.substring(0, 20), writing: page), isTrue);
      expect(
        isLeftoverPageWrite(page.substring(0, page.length - 7), writing: page),
        isTrue,
      );
    });

    test('never a copy of a page that a person edited', () {
      // The marker travels with a copy; the edit is what must not be lost.
      final edited = page.replaceFirst('One route.', 'One route, my notes.');
      expect(isLeftoverPageWrite(edited, writing: page), isFalse);
      expect(isLeftoverPageWrite('${page}My notes.\n', writing: page), isFalse);
    });

    test('never a file that is not a page', () {
      expect(isLeftoverPageWrite('my notes', writing: page), isFalse);
      expect(
        isLeftoverPageWrite('<!-- appstein:generated x', writing: page),
        isFalse,
      );
    });
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
