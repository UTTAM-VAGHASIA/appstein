import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  late String path;

  setUp(() {
    path = p.join(
      tempDir().path,
      '.dart_tool',
      'appstein',
      'analyzer_cache.bin',
    );
  });

  group('settled', () {
    test('keeps only the entries used since it was opened, as reopening the '
        'saved file would', () async {
      final path = p.join(tempDir().path, 'cache.bin');
      final first = AnalyzerCache.empty(path)
        ..putGet('a', Uint8List.fromList([1]))
        ..putGet('b', Uint8List.fromList([2]));
      await first.save();
      final reopened = AnalyzerCache.open(path)..get('a');
      final settled = reopened.settled();
      expect(settled.load, AnalyzerCacheLoad.loaded);
      expect(settled.loadedEntries, 1);
      expect(settled.get('a'), [1]);
      expect(settled.get('b'), isNull);
      expect(settled.path, path);
    });

    test('an unused cache settles to itself', () {
      final cache = AnalyzerCache.empty(p.join(tempDir().path, 'cache.bin'));
      expect(identical(cache.settled(), cache), isTrue);
    });
  });

  group('HeldAnalyzerCache', () {
    test('gives back the cache it keeps, settled, without reading the '
        'file', () {
      final path = p.join(tempDir().path, 'cache.bin');
      final held = HeldAnalyzerCache();
      final cache = held.take(path)..putGet('k', Uint8List.fromList([7]));
      held.keep(cache);
      File(path).writeAsStringSync('damaged');
      final again = held.take(path);
      expect(again.load, AnalyzerCacheLoad.loaded);
      expect(again.get('k'), [7]);
    });

    test('opens the file when it keeps nothing, or a cache of another '
        'path', () {
      final dir = tempDir().path;
      final held = HeldAnalyzerCache();
      expect(held.take(p.join(dir, 'a.bin')).load, AnalyzerCacheLoad.missing);
      held.keep(
        AnalyzerCache.empty(p.join(dir, 'b.bin'))
          ..putGet('k', Uint8List.fromList([1])),
      );
      expect(held.take(p.join(dir, 'a.bin')).get('k'), isNull);
    });
  });

  group('the cache file', () {
    test('a missing file opens as an empty cache', () {
      final cache = AnalyzerCache.open(path);
      expect(cache.load, AnalyzerCacheLoad.missing);
      expect(cache.damage, isNull);
      expect(cache.loadedEntries, 0);
      expect(cache.changed, isFalse);
    });

    test('what is saved opens again', () async {
      final cache = AnalyzerCache.open(path)
        ..putGet('a.key', bytes('one'))
        ..putGet('b.key', bytes('two'));
      expect(cache.addedEntries, 2);
      expect(cache.changed, isTrue);
      await cache.save();
      final again = AnalyzerCache.open(path);
      expect(again.load, AnalyzerCacheLoad.loaded);
      expect(again.loadedEntries, 2);
      expect(String.fromCharCodes(again.get('a.key')!), 'one');
      expect(again.get('missing.key'), isNull);
    });

    test('only the entries a run used are kept', () async {
      await (AnalyzerCache.open(path)
            ..putGet('a.key', bytes('one'))
            ..putGet('b.key', bytes('two')))
          .save();
      final cache = AnalyzerCache.open(path)..get('a.key');
      expect(cache.changed, isTrue);
      await cache.save();
      final again = AnalyzerCache.open(path);
      expect(again.loadedEntries, 1);
      expect(again.get('b.key'), isNull);
    });

    test(
      'a run that used every entry and added none changes nothing',
      () async {
        await (AnalyzerCache.open(path)..putGet('a.key', bytes('one'))).save();
        final cache = AnalyzerCache.open(path)..get('a.key');
        expect(cache.changed, isFalse);
      },
    );

    test('putGet keeps the bytes already stored', () async {
      await (AnalyzerCache.open(path)..putGet('a.key', bytes('one'))).save();
      final cache = AnalyzerCache.open(path);
      expect(
        String.fromCharCodes(cache.putGet('a.key', bytes('other'))),
        'one',
      );
      expect(cache.addedEntries, 0);
    });

    test('the same entries give the same bytes, whatever the order', () {
      final one = encodeAnalyzerCache({
        'b.key': bytes('2'),
        'a.key': bytes('1'),
      });
      final two = encodeAnalyzerCache({
        'a.key': bytes('1'),
        'b.key': bytes('2'),
      });
      expect(one, two);
      expect(decodeAnalyzerCache(one).keys, ['a.key', 'b.key']);
    });

    group('a damaged file opens as an empty cache that says why', () {
      void expectDamaged(List<int> content, String why) {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(content);
        final cache = AnalyzerCache.open(path);
        expect(cache.load, AnalyzerCacheLoad.damaged);
        expect(cache.damage, why);
        expect(cache.loadedEntries, 0);
      }

      test('not a cache', () {
        expectDamaged(bytes('hello'), 'it is not an Appstein analyzer cache');
      });

      test('another cache format', () {
        expectDamaged(
          encodeAnalyzerCache({}, format: 2),
          'it was written in cache format 2, not 1',
        );
      });

      test('another analyzer', () {
        expectDamaged(
          encodeAnalyzerCache({}, analyzer: '14.3.0'),
          'it was written by analyzer 14.3.0, not $analyzerVersion',
        );
      });

      test('cut short', () {
        final whole = encodeAnalyzerCache({'a.key': bytes('one')});
        expectDamaged(whole.sublist(0, whole.length - 2), 'it is cut short');
      });
    });

    test(
      'a cache that cannot be written throws KnowledgeWriteException',
      () async {
        // The folder the cache goes in is a file.
        final blocked = p.join(tempDir().path, 'blocked');
        File(blocked).writeAsStringSync('');
        final cache = AnalyzerCache.open(p.join(blocked, 'analyzer_cache.bin'))
          ..putGet('a.key', bytes('one'));
        await expectLater(
          cache.save(),
          throwsA(isA<KnowledgeWriteException>()),
        );
      },
    );

    test('it lives in .dart_tool/appstein', () {
      expect(
        analyzerCachePath('my app'),
        p.join('my app', '.dart_tool', 'appstein', 'analyzer_cache.bin'),
      );
    });
  });

  group('with the analyzer', () {
    test('the analyzer stores its work in the cache and reads it back '
        '(the canary for the analyzer src/ API)', () async {
      final app = copyFixtureApp();
      final cachePath = analyzerCachePath(app);
      final first = AnalyzerCache.open(cachePath);
      await (await ProjectAnalysis.analyze(
        app,
        dartSdkPath: testDartSdk,
        cache: first,
      )).dispose();
      expect(
        first.addedEntries,
        greaterThan(0),
        reason:
            'The analyzer no longer writes to the cache: check its ByteStore '
            'API after an analyzer upgrade.',
      );
      await first.save();
      final second = AnalyzerCache.open(cachePath);
      final analysis = await ProjectAnalysis.analyze(
        app,
        dartSdkPath: testDartSdk,
        cache: second,
      );
      await analysis.dispose();
      expect(analysis.libraries, isNotEmpty);
      expect(
        second.addedEntries,
        0,
        reason: 'The analyzer no longer reads from the cache.',
      );
      expect(second.changed, isFalse);
    });

    test('analyzerVersion is the exact version pubspec.yaml pins', () {
      final library = Isolate.resolvePackageUriSync(
        Uri.parse('package:appstein_engine/appstein_engine.dart'),
      )!;
      final pubspec =
          loadYaml(
                File(
                  p.join(
                    p.dirname(p.dirname(library.toFilePath())),
                    'pubspec.yaml',
                  ),
                ).readAsStringSync(),
              )
              as YamlMap;
      expect((pubspec['dependencies'] as YamlMap)['analyzer'], analyzerVersion);
    });
  });

  test('catchAnalyzerErrors turns an error nobody awaits into its '
      'result', () async {
    final result = catchAnalyzerErrors<int>(() async {
      // Like the analyzer's scheduler: an error on a future nobody awaits,
      // while the work itself waits forever.
      unawaited(Future<void>.error(StateError('from the scheduler')));
      await Completer<void>().future;
      return 1;
    });
    await expectLater(result, throwsA(isA<StateError>()));
  });

  test('catchAnalyzerErrors returns the result', () async {
    expect(await catchAnalyzerErrors(() async => 7), 7);
  });
}
