import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const meta = KnowledgeMeta(
    generatedAt: '2026-10-01T09:30:05Z',
    appsteinVersion: '0.1.0-dev',
    formatVersion: 1,
    sdkVersion: '3.47.5',
    inputHash: 'h1',
  );

  test('puts the meta in front matter, keys sorted, values as JSON', () {
    expect(
      markdownWithFrontMatter('# Delta\n\nBody.\n', meta),
      '---\n'
      'appsteinVersion: "0.1.0-dev"\n'
      'formatVersion: 1\n'
      'generatedAt: "2026-10-01T09:30:05Z"\n'
      'inputHash: "h1"\n'
      'sdkVersion: "3.47.5"\n'
      '---\n'
      '\n'
      '# Delta\n'
      '\n'
      'Body.\n',
    );
  });

  test('turns CRLF into LF and ends the text with exactly one newline', () {
    expect(
      markdownWithFrontMatter('# Delta\r\n\r\nBody.\r\n\r\n\r\n', meta),
      endsWith('---\n\n# Delta\n\nBody.\n'),
    );
  });

  test('reads back what it wrote', () {
    final read = readFrontMatter(markdownWithFrontMatter('# Delta\n', meta))!;
    expect(read.toJson(), meta.toJson());
  });

  for (final damaged in [
    '# Delta\n',
    '---\n---\n\n# Delta\n',
    '---\ngeneratedAt: 2026\n---\n\n# Delta\n',
    '---\nappsteinVersion "x"\n---\n',
    '---\nappsteinVersion: "x"\n',
    '---\nappsteinVersion: not json\n---\n',
  ]) {
    test('gives null for damaged front matter: ${damaged.split('\n')[1]}', () {
      expect(readFrontMatter(damaged), isNull);
    });
  }
}
