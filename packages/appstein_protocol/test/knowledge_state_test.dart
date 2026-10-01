import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips through JSON', () {
    const state = KnowledgeState(
      formatVersion: 1,
      appsteinVersion: '0.1.0-dev',
      lastSync: '2026-10-01T09:30:05Z',
      files: {'platform/sdk.json': 'h1', 'platform/toolchain.json': 'h2'},
    );
    final json = state.toJson();
    expect(json, {
      'formatVersion': 1,
      'appsteinVersion': '0.1.0-dev',
      'lastSync': '2026-10-01T09:30:05Z',
      'files': {'platform/sdk.json': 'h1', 'platform/toolchain.json': 'h2'},
    });
    expect(KnowledgeState.fromJson(json).toJson(), json);
  });

  test('file hashes must be strings', () {
    expect(
      () => KnowledgeState.fromJson({
        'formatVersion': 1,
        'appsteinVersion': 'x',
        'lastSync': 'x',
        'files': {'a': 1},
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'state.json: "files" must be an object of strings.',
        ),
      ),
    );
  });
}
