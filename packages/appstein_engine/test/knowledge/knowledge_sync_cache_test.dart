import 'dart:io';
import 'dart:typed_data';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/sync_harness.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
  });

  KnowledgeSync sync({bool analyzerCache = true}) => knowledgeSync(
    flutterRoot: sdk,
    runner: runner,
    analyzerCache: analyzerCache,
  );

  test('the first sync creates the analyzer cache, and the next one reads it '
      'without adding anything', () async {
    final app = copyFixtureApp();
    final first = await sync().run(app, dartSdkPath: testDartSdk);
    expect(first.analyzerCache!.load, AnalyzerCacheLoad.missing);
    final file = File(analyzerCachePath(app));
    expect(file.existsSync(), isTrue);
    final saved = file.readAsBytesSync();
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    expect(second.analyzerCache!.retried, isNull);
    // Nothing new, so the file wasn't rewritten.
    expect(file.readAsBytesSync(), saved);
  });

  test('the knowledge is the same with a warm cache as with none', () async {
    final none = copyFixtureApp();
    final warm = copyFixtureApp();
    await sync(analyzerCache: false).run(none, dartSdkPath: testDartSdk);
    expect(File(analyzerCachePath(none)).existsSync(), isFalse);
    await sync().run(warm, dartSdkPath: testDartSdk);
    Directory(p.join(warm, '.appstein')).deleteSync(recursive: true);
    final report = await sync().run(warm, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    expect(knowledgeFiles(warm), knowledgeFiles(none));
  });

  test('a damaged cache is not used, and is replaced', () async {
    final app = copyFixtureApp();
    File(analyzerCachePath(app))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('not a cache');
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.damaged);
    expect(
      report.analyzerCache!.damage,
      'it is not an Appstein analyzer cache',
    );
    expect(report.map!.skipped, isNull);
    expect(
      AnalyzerCache.open(analyzerCachePath(app)).load,
      AnalyzerCacheLoad.loaded,
    );
  });

  test('a cache whose entries are garbage makes the analysis run again '
      'without it, instead of ending the process', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final file = File(analyzerCachePath(app));
    final entries = decodeAnalyzerCache(file.readAsBytesSync());
    file.writeAsBytesSync(
      encodeAnalyzerCache({
        for (final MapEntry(:key, :value) in entries.entries)
          key: Uint8List(value.length)..fillRange(0, value.length, 0xFF),
      }),
    );
    Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.retried, isNotNull);
    expect(report.map!.skipped, isNull);
    for (final path in MapFiles.all) {
      final name = p.posix.basename(path);
      expectGolden(name, readMapBody(app, name));
    }
    // The garbage was replaced: the next sync reads the cache and adds
    // nothing.
    final next = await sync().run(app, dartSdkPath: testDartSdk);
    expect(next.analyzerCache!.retried, isNull);
    expect(next.analyzerCache!.load, AnalyzerCacheLoad.loaded);
  });

  test('a cache that cannot be saved is a warning; the sync still '
      'succeeds', () async {
    final app = copyFixtureApp();
    // Where the cache's folder goes, there is a file.
    File(p.join(app, '.dart_tool', 'appstein')).writeAsStringSync('');
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.saveError, isNotNull);
    expect(report.map!.skipped, isNull);
    expect(
      File(p.join(app, '.appstein', 'map', 'symbols.json')).existsSync(),
      isTrue,
    );
  });

  test('a skipped map leaves the cache alone', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(flutterCommand(sdk), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'offline'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.map!.skipped, isNotNull);
    expect(File(analyzerCachePath(app)).existsSync(), isFalse);
  });
}
