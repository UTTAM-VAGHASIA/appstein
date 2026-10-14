import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import 'support/analysis_support.dart';

/// How often each change is made and read back at once. A reading taken
/// without making the server take the change in was old in about half of
/// such readings (slice 1d.2, ticket 04).
const _rounds = 25;

// A real analysis server that is kept between readings (slice 1d.2, ticket
// 04): a reading is never older than the files on disk, never from a server
// that has died, and reports a plugin failure only while it holds. Every
// reading here is asked for at once after the change, with no wait.
void main() {
  late String app;
  late AnalysisServer server;

  setUp(() {
    // `mvvm app`, in a temp folder with a space and a non-ASCII letter.
    app = copyFixtureApp();
    server = realAnalysisServer(app);
    addTearDown(server.stop);
  });

  Future<List<String>> codes(String file) async => [
    for (final found in (await server.read()).diagnostics)
      if (found.file == file) found.code,
  ];

  File file(String relative) => File(p.joinAll([app, ...relative.split('/')]));

  test('an edit, a new file and a deleted file are each in the reading asked '
      'for at once, $_rounds times in a row, from one server', () async {
    writeProjectFile(app, 'lib/shape.dart', '''
/// A shape.
class Shape {
  /// How many sides it has.
  int sides = 0;
}
''');
    writeProjectFile(app, 'lib/uses_shape.dart', '''
import 'shape.dart';

/// Reads the sides.
int sidesOf(Shape shape) => shape.sides;
''');
    expect(await codes('lib/uses_shape.dart'), isEmpty);
    final processes = server.processes;
    expect(processes, isNotNull);

    final stale = <String>[];
    final costs = <int>[];
    Future<void> expectCodes(
      String what,
      String relative,
      List<String> expected,
    ) async {
      final watch = Stopwatch()..start();
      final found = await codes(relative);
      costs.add(watch.elapsedMilliseconds);
      if (found.join(',') != expected.join(',')) {
        stale.add('$what: $relative has $found, not $expected');
      }
    }

    for (var round = 0; round < _rounds; round++) {
      // An edit that breaks another file.
      writeProjectFile(app, 'lib/shape.dart', '''
/// A shape, round $round.
class Shape {
  /// How many corners it has.
  int corners = 0;
}
''');
      await expectCodes('round $round, after the edit', 'lib/uses_shape.dart', [
        'undefined_getter',
      ]);
      // A new file with an error of its own.
      writeProjectFile(
        app,
        'lib/new folder/added.dart',
        '/// Wrong, round $round.\nint wrong() => \'text\';\n',
      );
      await expectCodes(
        'round $round, after the new file',
        'lib/new folder/added.dart',
        ['return_of_invalid_type'],
      );
      // The new file is deleted, and the edit is taken back.
      deleteProjectFile(app, 'lib/new folder/added.dart');
      writeProjectFile(app, 'lib/shape.dart', '''
/// A shape, round $round.
class Shape {
  /// How many sides it has.
  int sides = 0;
}
''');
      await expectCodes(
        'round $round, after the delete',
        'lib/new folder/added.dart',
        [],
      );
      await expectCodes(
        'round $round, after the edit was taken back',
        'lib/uses_shape.dart',
        [],
      );
    }
    expect(stale, isEmpty, reason: stale.join('\n'));
    expect(server.processes, processes, reason: 'the server was restarted');

    // With nothing changed.
    final quiet = <int>[];
    for (var i = 0; i < 10; i++) {
      final watch = Stopwatch()..start();
      await server.read();
      quiet.add(watch.elapsedMilliseconds);
    }
    costs.sort();
    quiet.sort();
    printOnFailure('readings after a change: $costs ms');
    // What a reading costs on a kept server, for the record of the ticket.
    // ignore: avoid_print
    print(
      'A reading on a kept server, ${costs.length} after a change: median '
      '${costs[costs.length ~/ 2]} ms, most ${costs.last} ms; 10 with nothing '
      'changed: median ${quiet[5]} ms, most ${quiet.last} ms.',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a file that changes without changing its size or the second it was '
      'written in is still taken in', () async {
    writeProjectFile(app, 'lib/same.dart', '/// One.\nint one() => 12;\n');
    expect(await codes('lib/same.dart'), isEmpty);
    final stamp = file('lib/same.dart').lastModifiedSync();
    final size = file('lib/same.dart').lengthSync();
    // Same length, and the time of the first writing put back: only the
    // rule for a file written within 2 s of the last look can see it.
    writeProjectFile(app, 'lib/same.dart', '/// One.\nint one() => "";\n');
    file('lib/same.dart').setLastModifiedSync(stamp);
    expect(file('lib/same.dart').lengthSync(), size);
    expect(file('lib/same.dart').lastModifiedSync(), stamp);
    expect(await codes('lib/same.dart'), ['return_of_invalid_type']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('what the analysis reads outside the project folder', () {
    // The folder that holds `mvvm app` and `stubs`.
    late String work;

    setUp(() => work = p.dirname(app));

    void writeOutside(String relative, String content) =>
        File(p.joinAll([work, ...relative.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);

    /// Adds the package `kit`, in `local kit/` beside the app, to the
    /// app's package configuration, as pub writes a path dependency: with
    /// a relative location.
    void addKit({
      String config = '.dart_tool/package_config.json',
      bool absolute = false,
    }) {
      writeOutside('local kit/pubspec.yaml', 'name: kit\n');
      writeOutside('local kit/lib/kit.dart', '/// More.\nint extra = 1;\n');
      final json =
          jsonDecode(file(config).readAsStringSync()) as Map<String, Object?>;
      (json['packages']! as List).add({
        'name': 'kit',
        // Pub writes an absolute location for a `path:` given as one, and
        // for a package on another drive.
        'rootUri': absolute
            ? Uri.directory(p.join(work, 'local kit')).toString()
            : '../../local%20kit',
        'packageUri': 'lib/',
        'languageVersion': '3.12',
      });
      file(config).writeAsStringSync(jsonEncode(json));
      writeProjectFile(app, 'lib/uses_kit.dart', '''
import 'package:kit/kit.dart';

/// One more.
int more = extra;
''');
    }

    Future<List<(String, DiagnosticLevel)>> unused() async => [
      for (final found in (await server.read()).diagnostics)
        if (found.file == 'lib/unused.dart') (found.code, found.level),
    ];

    void writeUnused() => writeProjectFile(
      app,
      'lib/unused.dart',
      'import \'dart:math\';\n\n/// One.\nint one() => 1;\n',
    );

    for (final absolute in [false, true]) {
      test(
        'the source of a path dependency at a${absolute ? 'n absolute' : ' relative'} '
        'location: a change there is in the reading asked for at once, 10 '
        'times in a row, from one server',
        () async {
          addKit(absolute: absolute);
          expect(await codes('lib/uses_kit.dart'), isEmpty);
          final processes = server.processes;
          for (var round = 0; round < 10; round++) {
            writeOutside(
              'local kit/lib/kit.dart',
              '/// More, round $round.\nString extra = \'$round\';\n',
            );
            expect(await codes('lib/uses_kit.dart'), [
              'invalid_assignment',
            ], reason: 'round $round, broken');
            writeOutside(
              'local kit/lib/kit.dart',
              '/// More, round $round.\nint extra = $round;\n',
            );
            expect(
              await codes('lib/uses_kit.dart'),
              isEmpty,
              reason: 'round $round, mended',
            );
          }
          expect(
            server.processes,
            processes,
            reason: 'the server was restarted',
          );
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }

    test('an analysis_options.yaml above a project that has none', () async {
      writeUnused();
      writeOutside(
        'analysis_options.yaml',
        'analyzer:\n  errors:\n    unused_import: error\n',
      );
      expect(await unused(), [('unused_import', DiagnosticLevel.error)]);
      for (var round = 0; round < 3; round++) {
        writeOutside(
          'analysis_options.yaml',
          'analyzer:\n  errors:\n    unused_import: ignore\n# $round\n',
        );
        expect(await unused(), isEmpty, reason: 'round $round, ignored');
        writeOutside(
          'analysis_options.yaml',
          'analyzer:\n  errors:\n    unused_import: error\n# $round\n',
        );
        expect(await unused(), [
          ('unused_import', DiagnosticLevel.error),
        ], reason: 'round $round, an error');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a file the project\'s analysis_options.yaml includes: by a path '
        'outside the project, through a second include, and one that '
        'includes the first again', () async {
      writeUnused();
      writeProjectFile(
        app,
        'analysis_options.yaml',
        'include: ../shared options/first.yaml\n',
      );
      writeOutside('shared options/first.yaml', 'include: second.yaml\n');
      void second(String level, int round) => writeOutside(
        'shared options/second.yaml',
        // It includes the first again: the look must not go round for ever.
        'include: first.yaml\n'
            'analyzer:\n  errors:\n    unused_import: $level\n# $round\n',
      );
      second('error', 0);
      expect(await unused(), [('unused_import', DiagnosticLevel.error)]);
      for (var round = 1; round <= 3; round++) {
        second('info', round);
        expect(await unused(), [
          ('unused_import', DiagnosticLevel.info),
        ], reason: 'round $round, info');
        second('error', round);
        expect(await unused(), [
          ('unused_import', DiagnosticLevel.error),
        ], reason: 'round $round, an error');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a file the project\'s analysis_options.yaml includes from a '
        'package', () async {
      addKit();
      writeUnused();
      writeProjectFile(
        app,
        'analysis_options.yaml',
        'include: package:kit/options.yaml\n',
      );
      void options(String level, int round) => writeOutside(
        'local kit/lib/options.yaml',
        'analyzer:\n  errors:\n    unused_import: $level\n# $round\n',
      );
      options('error', 0);
      expect(await unused(), [('unused_import', DiagnosticLevel.error)]);
      for (var round = 1; round <= 3; round++) {
        options('info', round);
        expect(await unused(), [
          ('unused_import', DiagnosticLevel.info),
        ], reason: 'round $round, info');
        options('error', round);
        expect(await unused(), [
          ('unused_import', DiagnosticLevel.error),
        ], reason: 'round $round, an error');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a package configuration in the folder above, as a pub workspace '
        'has it: a package taken out of it and put back', () async {
      addKit();
      // The configuration moves up one folder; its locations follow.
      final own = file('.dart_tool/package_config.json');
      final json = jsonDecode(own.readAsStringSync()) as Map<String, Object?>;
      final packages = (json['packages']! as List).cast<Map<String, Object?>>();
      for (final package in packages) {
        package['rootUri'] = switch (package['rootUri']) {
          '../' => '../mvvm%20app',
          final String uri => uri.replaceFirst('../../', '../'),
          final other => other,
        };
      }
      Directory(p.join(app, '.dart_tool')).deleteSync(recursive: true);
      void config({required bool withKit}) => writeOutside(
        '.dart_tool/package_config.json',
        jsonEncode({
          ...json,
          'packages': [
            for (final package in packages)
              if (withKit || package['name'] != 'kit') package,
          ],
        }),
      );
      config(withKit: true);
      expect(await codes('lib/uses_kit.dart'), isEmpty);
      // The package's source is still followed from there.
      writeOutside(
        'local kit/lib/kit.dart',
        '/// More.\nString extra = \'\';\n',
      );
      expect(await codes('lib/uses_kit.dart'), ['invalid_assignment']);
      writeOutside('local kit/lib/kit.dart', '/// More.\nint extra = 2;\n');
      expect(await codes('lib/uses_kit.dart'), isEmpty);
      for (var round = 0; round < 3; round++) {
        config(withKit: false);
        expect(
          await codes('lib/uses_kit.dart'),
          contains('uri_does_not_exist'),
          reason: 'round $round, the package taken out',
        );
        config(withKit: true);
        expect(
          await codes('lib/uses_kit.dart'),
          isEmpty,
          reason: 'round $round, the package put back',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('analysis_options.yaml and the package configuration changed '
        'together, as `flutter pub get` may change them, start the server '
        'again once', () async {
      addKit();
      writeUnused();
      writeProjectFile(app, 'analysis_options.yaml', '# none yet\n');
      expect(await unused(), [('unused_import', DiagnosticLevel.warning)]);
      final (:guard, server: serverId) = server.processes!;
      await recordProcesses([guard, serverId]);

      writeProjectFile(
        app,
        'analysis_options.yaml',
        'analyzer:\n  errors:\n    unused_import: error\n',
      );
      final config = file('.dart_tool/package_config.json');
      config.writeAsStringSync('${config.readAsStringSync()}\n');
      final started = <({int guard, int server})?>{};
      // Looked at while the reading is taken: every server it starts.
      final watching = Stream<void>.periodic(
        const Duration(milliseconds: 20),
      ).listen((_) => started.add(server.processes));
      expect(await unused(), [('unused_import', DiagnosticLevel.error)]);
      await watching.cancel();
      started
        ..add(server.processes)
        ..remove(null)
        ..remove((guard: guard, server: serverId));
      expect(started, hasLength(1), reason: 'the servers started: $started');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  test('a server that died since the last reading is found out by this '
      'reading, which is answered by a new server, also when it is asked at '
      'once after the server was killed', () async {
    writeProjectFile(
      app,
      'lib/broken.dart',
      '/// Wrong on purpose.\nint wrong() => \'text\';\n',
    );
    expect(await codes('lib/broken.dart'), ['return_of_invalid_type']);
    for (var round = 0; round < 5; round++) {
      final (:guard, server: serverId) = server.processes!;
      // The error is fixed on disk, and the server this test started is
      // killed: an answer from its last reading would still have the error.
      writeProjectFile(
        app,
        'lib/broken.dart',
        '/// Right.\nint v$round = 1;\n',
      );
      // As they run now: the new server may be given one of their IDs.
      await recordProcesses([guard, serverId]);
      expect(Process.killPid(serverId, ProcessSignal.sigkill), isTrue);
      expect(await codes('lib/broken.dart'), isEmpty, reason: 'round $round');
      // The answer came from a new server: the old processes have ended,
      // and a server is running.
      expect(
        await goneWithin([guard, serverId], const Duration(seconds: 10)),
        isNotNull,
        reason: 'round $round: the dead server or its guard is still there',
      );
      final now = server.processes!;
      await recordProcesses([now.guard, now.server]);
      expect(await processAlive(now.guard), isTrue);
      expect(await processAlive(now.server), isTrue);
      writeProjectFile(
        app,
        'lib/broken.dart',
        '/// Wrong again.\nint wrong$round() => \'text\';\n',
      );
      expect(await codes('lib/broken.dart'), ['return_of_invalid_type']);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a plugin failure is in the reading only while its cause is in '
      'analysis_options.yaml, and a changed severity there is in the next '
      'reading', () async {
    writeProjectFile(
      app,
      'lib/unused.dart',
      'import \'dart:math\';\n\n/// One.\nint one() => 1;\n',
    );
    const ghost = 'plugins:\n  ghost_plugin:\n    path: ../no such plugin\n';
    writeProjectFile(app, 'analysis_options.yaml', ghost);
    final first = await server.read();
    expect(first.pluginFailures, hasLength(1));
    expect(first.pluginFailures.single, contains('ghost_plugin'));

    // The cause is removed, and a warning is made an error.
    writeProjectFile(
      app,
      'analysis_options.yaml',
      'analyzer:\n  errors:\n    unused_import: error\n',
    );
    final second = await server.read();
    expect(second.pluginFailures, isEmpty);
    expect(
      [
        for (final found in second.diagnostics)
          if (found.file == 'lib/unused.dart') (found.code, found.level),
      ],
      [('unused_import', DiagnosticLevel.error)],
    );

    // The cause comes back: so does the failure, once.
    writeProjectFile(app, 'analysis_options.yaml', ghost);
    final third = await server.read();
    expect(third.pluginFailures, hasLength(1));
    expect(
      [
        for (final found in third.diagnostics)
          if (found.file == 'lib/unused.dart') (found.code, found.level),
      ],
      [('unused_import', DiagnosticLevel.warning)],
    );
    // And it is still told by a reading that follows no change.
    expect((await server.read()).pluginFailures, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
