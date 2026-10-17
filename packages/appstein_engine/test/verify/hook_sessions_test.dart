import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
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
}
