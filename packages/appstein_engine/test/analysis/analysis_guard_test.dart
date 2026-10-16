import 'dart:async';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

// The guard's rule for when it deletes its server's half-written files
// ("shown to be gone", ticket 01 of slice 1d.7), with the questions it asks
// scripted. The real processes, the files a kill leaves and the guard's end
// are in analysis_server_test.dart.
void main() {
  group('removeServerFilesWhenGone', () {
    const serverId = 424242;
    late String cache;
    late File own;
    late File other;

    setUp(() {
      cache = tempDir().path;
      final driver = Directory(p.join(cache, analysisDriverFolder))
        ..createSync(recursive: true);
      own = File(p.join(driver.path, 'a.unlinked2-temp-$serverId'))
        ..writeAsStringSync('x');
      other = File(p.join(driver.path, 'b.unlinked2-temp-${serverId + 1}'))
        ..writeAsStringSync('x');
    });

    /// Runs the clean-up with [hasEnded] and the small waits of a test,
    /// returns how many files it deleted.
    Future<int> cleanUp({
      bool serverEnded = true,
      bool Function(int id)? hasEnded,
      String? Function()? cacheFolder,
      Future<int> Function(String, int)? remove,
      Duration serverEndWait = const Duration(milliseconds: 300),
      Duration budget = const Duration(seconds: 2),
    }) => removeServerFilesWhenGone(
      serverId,
      serverEnded: serverEnded,
      sinceEnding: Stopwatch()..start(),
      hasEnded: hasEnded ?? (_) => true,
      cacheFolder: cacheFolder ?? () => cache,
      remove: remove ?? removeHalfWrittenFiles,
      serverEndWait: serverEndWait,
      budget: budget,
    );

    test('the guard\'s budget is below the wait of the process that '
        'started it, with a margin, so that process never kills a guard '
        'at work', () {
      expect(
        analysisGuardEndBudget + const Duration(seconds: 1),
        lessThanOrEqualTo(analysisStopWait),
      );
    });

    test('the server is shown ended: only its files are deleted', () async {
      expect(await cleanUp(), 1);
      expect(own.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });

    test('the process is still ending for a while, then has ended: its '
        'files are deleted', () async {
      var asked = 0;
      expect(await cleanUp(hasEnded: (_) => ++asked > 5), 1);
      expect(asked, 6);
      expect(own.existsSync(), isFalse);
    });

    test('another process has the ID by now (it is never shown ended): '
        'nothing is deleted once the wait has run out', () async {
      final watch = Stopwatch()..start();
      expect(await cleanUp(hasEnded: (_) => false), 0);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
        reason: 'it gave up before its wait ran out',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(own.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    });

    test('the system never said the server ended: nothing is asked or '
        'deleted', () async {
      var asked = 0;
      expect(
        await cleanUp(
          serverEnded: false,
          hasEnded: (_) {
            asked++;
            return true;
          },
        ),
        0,
      );
      expect(asked, 0);
      expect(own.existsSync(), isTrue);
    });

    test('the server keeps no cache folder: nothing is deleted, and it '
        'does not throw', () async {
      expect(await cleanUp(cacheFolder: () => null), 0);
      expect(own.existsSync(), isTrue);
    });

    test('a question that fails leaves the files and does not throw', () async {
      expect(
        await cleanUp(hasEnded: (_) => throw const FileSystemException('x')),
        0,
      );
      expect(
        await cleanUp(cacheFolder: () => throw const FileSystemException('x')),
        0,
      );
      expect(
        await cleanUp(remove: (_, _) => throw const FileSystemException('x')),
        0,
      );
      expect(own.existsSync(), isTrue);
    });

    test('the wait took all of the budget: nothing is deleted', () async {
      var asked = 0;
      expect(
        await cleanUp(
          // Ended only after 100 ms, when the 50 ms budget is used up.
          hasEnded: (_) => ++asked > 10,
          serverEndWait: const Duration(seconds: 1),
          budget: const Duration(milliseconds: 50),
        ),
        0,
      );
      expect(own.existsSync(), isTrue);
    });

    test('a deletion that takes longer than what is left of the budget '
        'is given up at its end', () async {
      final never = Completer<int>();
      final watch = Stopwatch()..start();
      expect(
        await cleanUp(
          remove: (_, _) => never.future,
          budget: const Duration(milliseconds: 300),
        ),
        0,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
