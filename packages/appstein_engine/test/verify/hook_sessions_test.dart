import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String project;
  late HookSessions sessions;

  setUp(() {
    project = p.join(tempDir().path, 'my app');
    Directory(project).createSync();
    sessions = HookSessions(project);
  });

  List<File> records() => Directory(sessions.folder).existsSync()
      ? Directory(sessions.folder).listSync().whereType<File>().toList()
      : [];

  test('a session with no record reads as none', () {
    expect(sessions.read('s1'), isNull);
  });

  test('keeps the fingerprint per session, and replaces it', () async {
    expect(await sessions.saveFingerprint('s1', 'one'), isTrue);
    expect(await sessions.saveFingerprint('s2', 'two'), isTrue);
    expect(sessions.read('s1'), 'one');
    expect(sessions.read('s2'), 'two');
    expect(await sessions.saveFingerprint('s1', 'three'), isTrue);
    expect(sessions.read('s1'), 'three');
    expect(sessions.read('s2'), 'two');
  });

  test('the records are under .appstein/, beside state.json, so the project '
      'ignoring `.appstein/` ignores them too', () async {
    await sessions.saveFingerprint('s1', 'one');
    expect(p.isWithin(p.join(project, '.appstein'), sessions.folder), isTrue);
    expect(records(), hasLength(1));
  });

  test('a session ID that is no file name stays inside the folder', () async {
    for (final id in ['../../escape', r'a\b:c*?', 'with space', 'é' * 300]) {
      expect(await sessions.saveFingerprint(id, 'x'), isTrue, reason: id);
      expect(sessions.read(id), 'x', reason: id);
    }
    expect(records(), hasLength(4));
    expect(
      Directory(project).parent.listSync().map((e) => p.basename(e.path)),
      isNot(contains('escape')),
    );
  });

  test('a record that is damaged, or has no fingerprint, reads as none', () {
    Directory(sessions.folder).createSync(recursive: true);
    for (final text in ['', '{', '[1]', '{"fingerprint": 5}', '{}']) {
      File(sessions.fileOf('s1')).writeAsStringSync(text);
      expect(sessions.read('s1'), isNull, reason: text);
    }
  });

  test('records not written for a day are deleted by the next write; those '
      'written less long ago stay', () async {
    await sessions.saveFingerprint('old', 'a');
    await sessions.saveFingerprint('recent', 'b');
    await sessions.saveFingerprint('older', 'c');
    final now = DateTime.now();
    File(
      sessions.fileOf('old'),
    ).setLastModifiedSync(now.subtract(const Duration(days: 1, minutes: 1)));
    File(
      sessions.fileOf('older'),
    ).setLastModifiedSync(now.subtract(const Duration(days: 30)));
    File(
      sessions.fileOf('recent'),
    ).setLastModifiedSync(now.subtract(const Duration(hours: 23)));
    await sessions.saveFingerprint('new', 'd');
    expect(sessions.read('old'), isNull);
    expect(sessions.read('older'), isNull);
    expect(sessions.read('recent'), 'b');
    expect(sessions.read('new'), 'd');
    expect(records(), hasLength(2));
  });

  test('a stale temporary file of an old write is cleaned up too', () async {
    await sessions.saveFingerprint('s1', 'a');
    final leftover = File(p.join(sessions.folder, 'dead.json.tmp'))
      ..writeAsStringSync('{');
    leftover.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    await sessions.saveFingerprint('s1', 'b');
    expect(leftover.existsSync(), isFalse);
  });

  test('the lock is the records\' own, not the knowledge lock: a rebuild '
      'holding the knowledge lock does not keep a record from being '
      'saved', () async {
    final lock = await KnowledgeLock.acquire(p.join(project, '.appstein'));
    try {
      expect(await sessions.saveFingerprint('s1', 'x'), isTrue);
    } finally {
      lock.release();
    }
    expect(sessions.read('s1'), 'x');
  });

  test('many writes of one record at once leave it whole, and no temporary '
      'file', () async {
    final patient = HookSessions(
      project,
      lockTimeout: const Duration(seconds: 30),
    );
    final results = await Future.wait([
      for (var i = 0; i < 12; i++) patient.saveFingerprint('s1', 'print $i'),
    ]);
    expect(results, everyElement(isTrue));
    final text = File(sessions.fileOf('s1')).readAsStringSync();
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json['fingerprint'], matches(RegExp(r'^print \d+$')));
    expect(records().map((f) => p.extension(f.path)), everyElement('.json'));
    expect(records(), hasLength(1));
  });

  test('processes of their own saving one session\'s record at once leave it '
      'whole, always readable, and no temporary file behind', () async {
    // Found from the package, not from Directory.current: other test files
    // change the working directory, which is shared by the whole process.
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:appstein_engine/appstein_engine.dart'),
    );
    final writer = p.join(
      p.dirname(p.dirname(library!.toFilePath())),
      'test',
      'verify',
      'support',
      'hook_sessions_writer.dart',
    );
    const writers = 3;
    const saves = 40;
    final processes = [
      for (var i = 0; i < writers; i++)
        await Process.start(Platform.resolvedExecutable, [
          writer,
          project,
          'p$i',
          '$saves',
        ]),
    ];
    // Each prints `ready` once it is started and then waits for a line, so
    // none begins saving before every one is started: the saves overlap.
    final ready = [for (final _ in processes) Completer<void>()];
    final outputs = [
      for (final (i, process) in processes.indexed)
        process.stdout
            .transform(utf8.decoder)
            .map((text) {
              if (text.contains('ready') && !ready[i].isCompleted) {
                ready[i].complete();
              }
              return text;
            })
            .join()
            .then((text) => text.replaceFirst('ready\n', '')),
    ];
    final errors = [
      for (final process in processes)
        process.stderr.transform(utf8.decoder).join(),
    ];
    await Future.wait([
      for (final (i, process) in processes.indexed)
        ready[i].future.timeout(
          const Duration(seconds: 60),
          onTimeout: () => fail('writer $i did not start: ${process.pid}'),
        ),
    ]);
    for (final process in processes) {
      process.stdin.writeln('go');
      await process.stdin.flush();
    }
    var running = true;
    final exits = Future.wait([
      for (final process in processes) process.exitCode,
    ]).whenComplete(() => running = false);

    // While they write, read the record as a hook would: whenever it can be
    // read, it is a whole record of one of the writers. (On Windows a read
    // can meet the moment of a rename and fail; that is no record.)
    final wholeRecord = RegExp(r'^p\d-\d+$');
    var readable = 0;
    while (running) {
      final String text;
      try {
        text = File(sessions.fileOf('s1')).readAsStringSync();
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        continue;
      }
      readable++;
      final json = jsonDecode(text) as Map<String, Object?>;
      expect(json['fingerprint'], matches(wholeRecord), reason: text);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    for (final (i, code) in (await exits).indexed) {
      expect(code, 0, reason: 'writer $i: ${await errors[i]}');
      expect(await outputs[i], 'failed 0\n', reason: 'writer $i');
    }
    expect(readable, greaterThan(0));
    expect(sessions.read('s1'), matches(wholeRecord));
    // Only the record: no temporary file of a write is left behind.
    expect(records().map((f) => p.basename(f.path)), [
      p.basename(sessions.fileOf('s1')),
    ]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a lock that stays busy is a record not saved, not an error', () async {
    final busy = HookSessions(
      project,
      lockTimeout: const Duration(milliseconds: 100),
    );
    final lock = await KnowledgeLock.acquire(p.dirname(busy.folder));
    try {
      expect(await busy.saveFingerprint('s1', 'x'), isFalse);
    } finally {
      lock.release();
    }
    expect(busy.read('s1'), isNull);
    // And once it is free the next write works.
    expect(await busy.saveFingerprint('s1', 'x'), isTrue);
  });

  test('a folder that can\'t be written is a record not saved, not an '
      'error', () async {
    // `.appstein` is a file.
    File(p.join(project, '.appstein')).writeAsStringSync('not a folder');
    expect(await sessions.saveFingerprint('s1', 'x'), isFalse);
    expect(sessions.read('s1'), isNull);
  });

  group('the loop guard\'s count', () {
    test('a session with no count reads as none', () {
      expect(sessions.readGuard('s1'), isNull);
    });

    test('is kept per session, and replaced', () async {
      expect(
        await sessions.saveGuard(
          's1',
          const LoopGuard(errorsKey: 'a', count: 1),
        ),
        isTrue,
      );
      expect(
        await sessions.saveGuard(
          's2',
          const LoopGuard(errorsKey: 'b', count: 2),
        ),
        isTrue,
      );
      expect(sessions.readGuard('s1')!.errorsKey, 'a');
      expect(sessions.readGuard('s1')!.count, 1);
      expect(sessions.readGuard('s2')!.errorsKey, 'b');
      expect(sessions.readGuard('s2')!.count, 2);
      await sessions.saveGuard('s1', const LoopGuard(errorsKey: 'a', count: 2));
      expect(sessions.readGuard('s1')!.count, 2);
      expect(sessions.readGuard('s2')!.count, 2);
    });

    test('and the fingerprint are two parts of one record: saving one '
        'keeps the other, in either order', () async {
      await sessions.saveFingerprint('s1', 'print');
      await sessions.saveGuard('s1', const LoopGuard(errorsKey: 'a', count: 2));
      expect(sessions.read('s1'), 'print');
      expect(sessions.readGuard('s1')!.count, 2);

      // The agent edits between two Stop runs: the after-edit hook saves the
      // fingerprint and the count must stay.
      await sessions.saveFingerprint('s1', 'other print');
      expect(sessions.read('s1'), 'other print');
      expect(sessions.readGuard('s1')!.errorsKey, 'a');
      expect(sessions.readGuard('s1')!.count, 2);

      // Removing the count keeps the fingerprint.
      expect(await sessions.saveGuard('s1', null), isTrue);
      expect(sessions.readGuard('s1'), isNull);
      expect(sessions.read('s1'), 'other print');
      expect(records(), hasLength(1));
    });

    test('removing a count that is not there writes nothing', () async {
      expect(await sessions.saveGuard('s1', null), isTrue);
      expect(records(), isEmpty);
      await sessions.saveFingerprint('s1', 'print');
      final record = File(sessions.fileOf('s1'));
      final before = record.lastModifiedSync();
      record.setLastModifiedSync(before.subtract(const Duration(hours: 1)));
      final set = record.lastModifiedSync();
      expect(await sessions.saveGuard('s1', null), isTrue);
      expect(record.lastModifiedSync(), set);
    });

    test('a count that is damaged reads as none', () {
      Directory(sessions.folder).createSync(recursive: true);
      for (final text in [
        '{',
        '{"guard": 5}',
        '{"guard": {}}',
        '{"guard": {"errors": "a"}}',
        '{"guard": {"errors": "a", "count": "2"}}',
        '{"guard": {"errors": "a", "count": 0}}',
        '{"guard": {"errors": 5, "count": 2}}',
      ]) {
        File(sessions.fileOf('s1')).writeAsStringSync(text);
        expect(sessions.readGuard('s1'), isNull, reason: text);
      }
    });

    test('saving over a damaged record leaves a whole one', () async {
      Directory(sessions.folder).createSync(recursive: true);
      File(sessions.fileOf('s1')).writeAsStringSync('{ not json');
      expect(
        await sessions.saveGuard(
          's1',
          const LoopGuard(errorsKey: 'a', count: 1),
        ),
        isTrue,
      );
      expect(sessions.readGuard('s1')!.count, 1);
    });

    test('a lock that stays busy is a count not saved: the count is the one '
        'before, and nothing throws', () async {
      await sessions.saveGuard('s1', const LoopGuard(errorsKey: 'a', count: 1));
      final busy = HookSessions(
        project,
        lockTimeout: const Duration(milliseconds: 100),
      );
      final lock = await KnowledgeLock.acquire(p.dirname(busy.folder));
      try {
        expect(
          await busy.saveGuard('s1', const LoopGuard(errorsKey: 'a', count: 2)),
          isFalse,
        );
        expect(await busy.saveGuard('s1', null), isFalse);
      } finally {
        lock.release();
      }
      expect(busy.readGuard('s1')!.count, 1);
    });

    test('whether there is a count to remove is judged under the lock: with '
        'the lock busy the removal is not taken for done, whether or not '
        'a count is there', () async {
      final busy = HookSessions(
        project,
        lockTimeout: const Duration(milliseconds: 100),
      );
      // No record at all: still not "nothing to remove", since that can't be
      // known without the lock (a read outside it can fail during another
      // write's rename and miss a count that is there).
      final lock = await KnowledgeLock.acquire(p.dirname(busy.folder));
      try {
        expect(await busy.saveGuard('s1', null), isFalse);
      } finally {
        lock.release();
      }
      expect(await busy.saveGuard('s1', null), isTrue);
    });

    test('a removal and fingerprint saves at once leave no stale count, '
        'whatever the order', () async {
      final patient = HookSessions(
        project,
        lockTimeout: const Duration(seconds: 30),
      );
      for (var round = 0; round < 15; round++) {
        await patient.saveGuard(
          's1',
          const LoopGuard(errorsKey: 'a', count: 2),
        );
        await Future.wait([
          for (var i = 0; i < 6; i++) patient.saveFingerprint('s1', 'p$i'),
          patient.saveGuard('s1', null),
          for (var i = 0; i < 6; i++) patient.saveFingerprint('s1', 'q$i'),
        ]);
        expect(patient.readGuard('s1'), isNull, reason: 'round $round');
        expect(patient.read('s1'), isNotNull, reason: 'round $round');
      }
    });

    test('a save waits for a busy lock for the time it is given: one that '
        'is let go of within it is saved, and the Stop hook\'s wait is '
        '2 s', () async {
      expect(stopSaveLockWait, const Duration(seconds: 2));
      final patient = HookSessions(
        project,
        lockTimeout: const Duration(seconds: 5),
      );
      final lock = await KnowledgeLock.acquire(p.dirname(patient.folder));
      Timer(const Duration(milliseconds: 700), lock.release);
      expect(
        await patient.saveGuard(
          's1',
          const LoopGuard(errorsKey: 'a', count: 1),
        ),
        isTrue,
      );
      expect(patient.readGuard('s1')!.count, 1);
    });

    test('a folder that can\'t be written is a count not saved', () async {
      File(p.join(project, '.appstein')).writeAsStringSync('not a folder');
      expect(
        await sessions.saveGuard(
          's1',
          const LoopGuard(errorsKey: 'a', count: 1),
        ),
        isFalse,
      );
      expect(sessions.readGuard('s1'), isNull);
    });
  });

  group('errorSetKey', () {
    Finding error(String id, String? file, String message, {int? line}) =>
        Finding(
          id: id,
          severity: Severity.error,
          file: file,
          line: line,
          message: message,
        );

    test('is the same for the same errors on other lines, in another order, '
        'and with one twice', () {
      final key = errorSetKey([
        error('a.x', 'lib/a.dart', 'Broken.', line: 3),
        error('b.y', 'lib/b.dart', 'Wrong.', line: 9),
      ]);
      expect(
        errorSetKey([
          error('b.y', 'lib/b.dart', 'Wrong.', line: 40),
          error('a.x', 'lib/a.dart', 'Broken.', line: 13),
          error('a.x', 'lib/a.dart', 'Broken.', line: 14),
        ]),
        key,
      );
    });

    test('differs when the check, the file or the message differs, or an '
        'error is added or fixed', () {
      final base = [error('a.x', 'lib/a.dart', 'Broken.')];
      final key = errorSetKey(base);
      for (final other in [
        [error('a.z', 'lib/a.dart', 'Broken.')],
        [error('a.x', 'lib/b.dart', 'Broken.')],
        [error('a.x', null, 'Broken.')],
        [error('a.x', 'lib/a.dart', 'Broken again.')],
        [...base, error('b.y', 'lib/b.dart', 'Wrong.')],
        <Finding>[],
      ]) {
        expect(errorSetKey(other), isNot(key));
      }
    });

    test('does not mix the fields: a file and a message that run together '
        'are not another file and message', () {
      expect(
        errorSetKey([error('a', 'b c', 'd')]),
        isNot(errorSetKey([error('a', 'b', 'c d')])),
      );
    });
  });

  group('decideLoopGuard', () {
    Finding error(String file) => Finding(
      id: 'x.err',
      severity: Severity.error,
      file: file,
      message: 'Broken.',
    );

    final errors = [error('lib/a.dart')];
    final key = errorSetKey(errors);

    test('the first three runs with the same errors block, the fourth lets '
        'the agent go, and so do the ones after it', () {
      LoopGuard? saved;
      final letGo = <bool>[];
      for (var run = 0; run < 6; run++) {
        final decision = decideLoopGuard(saved, errors, continuing: run > 0);
        letGo.add(decision.letGo);
        saved = decision.count;
      }
      expect(letGo, [false, false, false, true, true, true]);
      expect(saved!.errorsKey, key);
      // The count stops one past the limit.
      expect(saved.count, loopGuardLimit + 1);
    });

    test('no errors let nobody go and remove the count', () {
      final decision = decideLoopGuard(
        LoopGuard(errorsKey: key, count: 3),
        const [],
        continuing: true,
      );
      expect(decision.letGo, isFalse);
      expect(decision.count, isNull);
    });

    test('changed errors, or an agent that is not continuing, start at 1', () {
      final last = LoopGuard(errorsKey: key, count: 3);
      final changed = decideLoopGuard(last, [
        error('lib/b.dart'),
      ], continuing: true);
      expect(changed.letGo, isFalse);
      expect(changed.count!.count, 1);
      final fresh = decideLoopGuard(last, errors, continuing: false);
      expect(fresh.letGo, isFalse);
      expect(fresh.count!.count, 1);
    });
  });

  group('nextBlockCount', () {
    const last = LoopGuard(errorsKey: 'a', count: 2);

    test('goes up by one for the same errors while the agent is '
        'continuing', () {
      expect(nextBlockCount(last, 'a', continuing: true), 3);
    });

    test('starts again at 1 when the errors change, when the agent is not '
        'continuing, or when there is no count', () {
      expect(nextBlockCount(last, 'b', continuing: true), 1);
      expect(nextBlockCount(last, 'a', continuing: false), 1);
      expect(nextBlockCount(null, 'a', continuing: true), 1);
      expect(nextBlockCount(null, 'a', continuing: false), 1);
    });

    test('the limit is 3', () {
      expect(loopGuardLimit, 3);
    });
  });
}
