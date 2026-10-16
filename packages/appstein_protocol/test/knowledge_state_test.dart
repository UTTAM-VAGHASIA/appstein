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

  test('a state.json from before slice 1d.2 reads as having no unverified '
      'files and no Dart file hashes', () {
    final state = KnowledgeState.fromJson(json());
    expect(state.unverified, isEmpty);
    expect(state.dartFiles, isNull);
    expect(state.toJson(), isNot(contains('unverified')));
    expect(state.toJson(), isNot(contains('dartFiles')));
  });

  test('the unverified files and the Dart file hashes round-trip', () {
    final withBoth = json()
      ..['dartFiles'] = {'lib/main.dart': 'd1', 'bin/tool.dart': 'unreadable'}
      ..['unverified'] = ['bin/tool.dart', 'lib/main.dart']
      ..['dartStamps'] = {'lib/main.dart': '1700000000000000/12'}
      ..['dartScannedAt'] = '2026-10-14T09:00:00.000Z';
    final state = KnowledgeState.fromJson(withBoth);
    expect(state.dartFiles, {
      'lib/main.dart': 'd1',
      'bin/tool.dart': 'unreadable',
    });
    expect(state.unverified, ['bin/tool.dart', 'lib/main.dart']);
    expect(state.toJson(), withBoth);
    expect(
      () => KnowledgeState.fromJson(json()..['unverified'] = [1]),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'state.json: "unverified" must be a list of strings.',
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
