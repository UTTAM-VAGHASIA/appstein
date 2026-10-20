import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/analysis_hosts.dart';
import '../tool/src/process_memory.dart';

// The tool's way to find and end the analysis hosts of its own folder, with
// scripted process lists: no process is started or ended.
void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('appstein hosts ');
    addTearDown(() => folder.deleteSync(recursive: true));
  });

  File address(String hash, int processId, {String extension = 'json'}) =>
      File(p.join(folder.path, 'host-$hash.$extension'))..writeAsStringSync(
        jsonEncode({
          'port': 5000,
          'secret': 'secret',
          'processId': processId,
          'appsteinVersion': '0.1.0',
        }),
      );

  group('hostProcessIds', () {
    test('is empty for a folder that does not exist', () {
      expect(hostProcessIds(p.join(folder.path, 'none')), isEmpty);
    });

    test('is the process ID of each address file, and no other file '
        'counts: not a lock, a failure note or a file that is no address', () {
      address('a', 100);
      address('b', 200);
      address('a', 300, extension: 'lock');
      address('c', 400, extension: 'failed');
      File(p.join(folder.path, 'host-d.json')).writeAsStringSync('not json');
      File(p.join(folder.path, 'other.json')).writeAsStringSync('{}');
      expect(hostProcessIds(folder.path)..sort(), [100, 200]);
    });
  });

  group('stopHosts', () {
    test(
      'does nothing, and asks nothing, when no host has an address',
      () async {
        var asked = 0;
        var killed = 0;
        final problem = await stopHosts(
          folder.path,
          lister: () async {
            asked++;
            return const [];
          },
          kill: (_) {
            killed++;
            return true;
          },
        );
        expect(problem, isNull);
        expect(asked, 0);
        expect(killed, 0);
      },
    );

    test('kills the host, waits until it and its guard and server are '
        'gone, and deletes its address file', () async {
      final file = address('a', 100);
      final killed = <int>[];
      var running = true;
      final problem = await stopHosts(
        folder.path,
        goneDelay: Duration.zero,
        lister: () async => [
          ProcessRow(pid, 1, 1 << 20, 1000),
          if (running) ...[
            const ProcessRow(100, 1, 1 << 20, 2000),
            const ProcessRow(101, 100, 1 << 20, 2100),
            const ProcessRow(102, 101, 1 << 20, 2200),
          ],
        ],
        kill: (id) {
          killed.add(id);
          running = false;
          return true;
        },
      );
      expect(problem, isNull);
      expect(killed, [100]);
      expect(file.existsSync(), isFalse);
    });

    test('waits for a guard and a server that end a moment after the '
        'host', () async {
      address('a', 100);
      var listings = 0;
      var killedAt = -1;
      final problem = await stopHosts(
        folder.path,
        goneDelay: Duration.zero,
        lister: () async {
          listings++;
          // The guard and the server are still there two listings after
          // the kill.
          final stillRunning = killedAt < 0 || listings <= killedAt + 2;
          return [
            ProcessRow(pid, 1, 1 << 20, 1000),
            if (killedAt < 0) const ProcessRow(100, 1, 1 << 20, 2000),
            if (stillRunning) ...[
              const ProcessRow(101, 100, 1 << 20, 2100),
              const ProcessRow(102, 101, 1 << 20, 2200),
            ],
          ];
        },
        kill: (id) {
          killedAt = listings;
          return true;
        },
      );
      expect(problem, isNull);
      expect(listings, greaterThan(3));
    });

    test('names a process of the host that is still running, by ID, with '
        'the command to end it', () async {
      address('a', 100);
      final problem = await stopHosts(
        folder.path,
        goneAttempts: 3,
        goneDelay: Duration.zero,
        lister: () async => [
          ProcessRow(pid, 1, 1 << 20, 1000),
          const ProcessRow(100, 1, 1 << 20, 2000),
          const ProcessRow(101, 100, 1 << 20, 2100),
        ],
        kill: (_) => true,
      );
      expect(problem, contains('100'));
      expect(problem, contains('101'));
      expect(problem, contains('still running'));
      expect(problem, anyOf(contains('taskkill'), contains('kill <id>')));
    });

    test('does not name a program that was given the ID of a process '
        'of the host after it ended', () async {
      address('a', 100);
      var killed = false;
      final far = DateTime.now().millisecondsSinceEpoch + 600000;
      final problem = await stopHosts(
        folder.path,
        goneDelay: Duration.zero,
        lister: () async => [
          ProcessRow(pid, 1, 1 << 20, 1000),
          if (!killed) const ProcessRow(100, 1, 1 << 20, 2000),
          // The ID of the host, given to another program that started later.
          if (killed) ProcessRow(100, 1, 1 << 20, far),
        ],
        kill: (_) => killed = true,
      );
      expect(problem, isNull);
    });

    test('a listing that fails is a problem, not a pass', () async {
      address('a', 100);
      var listings = 0;
      final problem = await stopHosts(
        folder.path,
        goneDelay: Duration.zero,
        lister: () async {
          if (++listings > 1) throw StateError('the process list failed');
          return [
            ProcessRow(pid, 1, 1 << 20, 1000),
            const ProcessRow(100, 1, 1 << 20, 2000),
          ];
        },
        kill: (_) => true,
      );
      expect(problem, contains('the process list failed'));
    });

    group('a process ID is killed only while it still belongs to the host', () {
      // The address file is written by the host a moment after it started, so
      // the host started before the file did. A process that started after
      // the file was written was given the ID of a host that has ended.
      int afterTheFile() => DateTime.now().millisecondsSinceEpoch + 600000;

      test('a reused process ID is not killed, and is reported', () async {
        final file = address('a', 100);
        final killed = <int>[];
        final problem = await stopHosts(
          folder.path,
          goneDelay: Duration.zero,
          lister: () async => [
            ProcessRow(pid, 1, 1 << 20, 1000),
            ProcessRow(100, 1, 1 << 20, afterTheFile(), 'someone-else'),
          ],
          kill: (id) {
            killed.add(id);
            return true;
          },
        );
        expect(killed, isEmpty);
        expect(
          problem,
          allOf(contains('100'), contains('not the analysis host')),
        );
        // The address was a dead host's: it goes, so the next client does not
        // trust it.
        expect(file.existsSync(), isFalse);
      });

      test('a process whose start is not known is not killed either: it '
          'cannot be shown to be the host', () async {
        address('a', 100);
        final killed = <int>[];
        final problem = await stopHosts(
          folder.path,
          goneDelay: Duration.zero,
          lister: () async => [
            ProcessRow(pid, 1, 1 << 20, 1000),
            const ProcessRow(100, 1, 1 << 20),
          ],
          kill: (id) {
            killed.add(id);
            return true;
          },
        );
        expect(killed, isEmpty);
        expect(problem, allOf(contains('100'), contains('cannot be shown')));
      });

      test('a listing that failed before the kill kills nothing', () async {
        address('a', 100);
        final killed = <int>[];
        final problem = await stopHosts(
          folder.path,
          goneDelay: Duration.zero,
          lister: () async => throw StateError('the process list failed'),
          kill: (id) {
            killed.add(id);
            return true;
          },
        );
        expect(killed, isEmpty);
        expect(problem, contains('the process list failed'));
      });

      test('a host that started a second before its file was written is '
          'killed, and so is one the listing puts a second after it (the '
          'precision of a listing)', () async {
        address('a', 100);
        final killed = <int>[];
        await stopHosts(
          folder.path,
          goneDelay: Duration.zero,
          lister: () async => [
            ProcessRow(pid, 1, 1 << 20, 1000),
            ProcessRow(
              100,
              1,
              1 << 20,
              DateTime.now().millisecondsSinceEpoch + 1000,
            ),
          ],
          kill: (id) {
            killed.add(id);
            return true;
          },
        );
        expect(killed, [100]);
      });

      test('a host that has already ended (no such process) needs no kill '
          'and is no problem', () async {
        address('a', 100);
        final killed = <int>[];
        final problem = await stopHosts(
          folder.path,
          goneDelay: Duration.zero,
          lister: () async => [ProcessRow(pid, 1, 1 << 20, 1000)],
          kill: (id) {
            killed.add(id);
            return true;
          },
        );
        expect(killed, isEmpty);
        expect(problem, isNull);
      });
    });

    test('ends every host of the folder', () async {
      address('a', 100);
      address('b', 200);
      final killed = <int>[];
      final problem = await stopHosts(
        folder.path,
        goneDelay: Duration.zero,
        lister: () async => [
          ProcessRow(pid, 1, 1 << 20, 1000),
          if (killed.isEmpty) ...[
            const ProcessRow(100, 1, 1 << 20, 2000),
            const ProcessRow(200, 1, 1 << 20, 2000),
          ],
        ],
        kill: (id) {
          killed.add(id);
          return true;
        },
      );
      expect(problem, isNull);
      expect(killed..sort(), [100, 200]);
      expect(hostProcessIds(folder.path), isEmpty);
    });
  });
}
