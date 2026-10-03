import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> json({Object? files}) => {
    'formatVersion': 1,
    'appsteinVersion': '0.1.0-dev',
    'lastSync': '2026-10-01T09:30:05Z',
    'files': files ?? {'platform/sdk.json': 'h1'},
    'sources': {'project:lib/main.dart': 's1', 'pubspec.lock': 'missing'},
    'written': {'platform/sdk.json': 'w1'},
    'changed': ['project:lib/main.dart'],
  };

  test('round-trips through JSON', () {
    const state = KnowledgeState(
      formatVersion: 1,
      appsteinVersion: '0.1.0-dev',
      lastSync: '2026-10-01T09:30:05Z',
      files: {'platform/sdk.json': 'h1'},
      sources: {'project:lib/main.dart': 's1', 'pubspec.lock': 'missing'},
      written: {'platform/sdk.json': 'w1'},
      changed: ['project:lib/main.dart'],
    );
    expect(state.toJson(), json());
    expect(KnowledgeState.fromJson(json()).toJson(), json());
  });

  test('file hashes must be strings', () {
    expect(
      () => KnowledgeState.fromJson(json(files: {'a': 1})),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'state.json: "files" must be an object of strings.',
        ),
      ),
    );
  });

  test('a state.json from before 1b.7, without sources, is an error', () {
    expect(
      () => KnowledgeState.fromJson(json()..remove('sources')),
      throwsFormatException,
    );
  });
}
