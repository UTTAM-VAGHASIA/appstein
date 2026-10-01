import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const meta = KnowledgeMeta(
    generatedAt: '2026-10-01T09:30:05Z',
    appsteinVersion: '0.1.0-dev',
    formatVersion: knowledgeFormatVersion,
    sdkVersion: '3.47.5',
    inputHash: 'abc123',
  );

  test('round-trips through JSON with the spec §6.2 key names', () {
    final json = meta.toJson();
    expect(json, {
      'generatedAt': '2026-10-01T09:30:05Z',
      'appsteinVersion': '0.1.0-dev',
      'formatVersion': 1,
      'sdkVersion': '3.47.5',
      'inputHash': 'abc123',
    });
    final back = KnowledgeMeta.fromJson(json);
    expect(back.toJson(), json);
  });

  test('a missing field names the file', () {
    expect(
      () => KnowledgeMeta.fromJson({'generatedAt': 'x'}, file: 'sdk.json'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          startsWith('sdk.json: '),
        ),
      ),
    );
  });

  test('times are UTC, to the second, with a Z', () {
    expect(
      formatKnowledgeTime(DateTime.utc(2026, 10, 1, 9, 30, 5, 123)),
      '2026-10-01T09:30:05Z',
    );
    expect(
      formatKnowledgeTime(DateTime.utc(2026, 1, 2, 3, 4, 5).toLocal()),
      '2026-01-02T03:04:05Z',
    );
  });
}
