import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/command_run.dart';
import '../tool/src/terminal_verify.dart';

/// The text of a full run on the measured app, as `appstein verify` prints
/// it, with [before] put in front of the summary line.
String fullOutput({String before = ''}) =>
    'docs/app/routes.md\n'
    '  warning docs.stale: The page was edited by hand; `appstein docs` will '
    'overwrite the edit.\n'
    '    fix: Run `appstein docs`.\n'
    '\n'
    'lib/ui/feature_0\n'
    '  warning verify.test_required: The feature `feature_0` has no test.\n'
    '\n'
    '$before'
    '0 errors, 2 warnings, 0 info. No findings suppressed.\n';

void main() {
  group('terminalVerifyProblem', () {
    test('accepts a fast run that found nothing', () {
      expect(
        terminalVerifyProblem(0, '$fastSummary\n', '', fast: true),
        isNull,
      );
    });

    test('accepts a full run with warnings and the edited page', () {
      expect(terminalVerifyProblem(0, fullOutput(), '', fast: false), isNull);
    });

    test('accepts a full run with one warning: "1 warning"', () {
      final one = fullOutput()
          .replaceFirst('lib/ui/feature_0\n', '')
          .replaceFirst(RegExp(r'  warning verify\.test_required.*\n\n'), '')
          .replaceFirst('2 warnings', '1 warning');
      expect(terminalVerifyProblem(0, one, '', fast: false), isNull);
    });

    test('refuses a run that exited with anything but 0', () {
      expect(
        terminalVerifyProblem(3, '', 'the analysis server failed', fast: false),
        allOf(contains('exit code 3'), contains('the analysis server failed')),
      );
    });

    test('refuses a fast run that named a check as not run, though its last '
        'line is the summary', () {
      expect(
        terminalVerifyProblem(
          0,
          'Not run:\n  dart.unformatted: the analysis server did not '
              'answer within 1 s for 200 files\n\n$fastSummary\n',
          '',
          fast: true,
        ),
        contains('not run'),
      );
    });

    test('refuses a full run that named a check as not run', () {
      expect(
        terminalVerifyProblem(
          0,
          fullOutput(before: 'Not run:\n  test.failed: why\n\n'),
          '',
          fast: false,
        ),
        contains('not run'),
      );
    });

    test('refuses a run that printed a notice', () {
      expect(
        terminalVerifyProblem(
          0,
          'Note:\n  Process 12 may be an analysis server.\n\n$fastSummary\n',
          '',
          fast: true,
        ),
        contains('notice'),
      );
    });

    test('refuses a fast run with a finding', () {
      expect(
        terminalVerifyProblem(
          0,
          'lib/routing/router.dart\n  warning dart.unformatted: x\n\n'
              '0 errors, 1 warning, 0 info. No findings suppressed.\n',
          '',
          fast: true,
        ),
        contains('its last line is "0 errors, 1 warning'),
      );
    });

    test('refuses a full run with an error, info or a suppression', () {
      for (final summary in [
        '1 error, 2 warnings, 0 info. No findings suppressed.',
        '0 errors, 2 warnings, 1 info. No findings suppressed.',
        '0 errors, 2 warnings, 0 info. 1 finding suppressed by 1 suppression.',
      ]) {
        expect(
          terminalVerifyProblem(
            0,
            fullOutput().replaceFirst(
              '0 errors, 2 warnings, 0 info. No findings suppressed.',
              summary,
            ),
            '',
            fast: false,
          ),
          contains('its last line is "$summary"'),
          reason: summary,
        );
      }
    });

    test('accepts docs.stale wherever it is in the group of routes.md', () {
      final later = fullOutput().replaceFirst(
        'docs/app/routes.md\n',
        'docs/app/routes.md\n  warning other.check: something else.\n'
            '    fix: Do this.\n',
      );
      expect(terminalVerifyProblem(0, later, '', fast: false), isNull);
    });

    test('refuses docs.stale that is in the group of another file', () {
      final elsewhere = fullOutput().replaceFirst(
        'docs/app/routes.md\n',
        'docs/app/README.md\n',
      );
      expect(
        terminalVerifyProblem(0, elsewhere, '', fast: false),
        contains('did not report docs.stale'),
      );
    });

    test('refuses a "full" run that did not check the docs: it ran the fast '
        'checks only', () {
      expect(
        terminalVerifyProblem(0, '$fastSummary\n', '', fast: false),
        contains('did not report docs.stale'),
      );
    });
  });

  group('terminalRunCutByCap', () {
    const cutText =
        'Appstein could not finish checking: the analysis server is starting '
        'or busy. Checks still pending: dart.error. This run exits 3 and not '
        '0 or 1: run it again, or raise verify.fast_timeout_seconds.';

    test('is a run that exited 3 and said Appstein could not finish '
        'checking', () {
      expect(
        terminalRunCutByCap(3, 'Not run:\n  dart.error: x\n', cutText),
        isTrue,
      );
    });

    test('is not any other run: not an exit 3 that says something else, '
        'not the same words with another exit code', () {
      expect(terminalRunCutByCap(3, '', 'the analysis server failed'), isFalse);
      expect(terminalRunCutByCap(1, '', cutText), isFalse);
      expect(terminalRunCutByCap(0, '$fastSummary\n', ''), isFalse);
    });
  });

  group('terminalCutProblem', () {
    test('names the cap, its default, the time and the flag, and says the '
        'row fails and the cap is not raised', () {
      final problem = terminalCutProblem(
        fastFlag,
        'a cold run',
        elapsed: const Duration(milliseconds: 20412),
        stdout: 'Not run:\n  dart.error: still pending\n',
        stderr: 'Appstein could not finish checking: x',
      );
      expect(problem, contains('appstein verify --fast (a cold run)'));
      expect(problem, contains('verify.fast_timeout_seconds'));
      expect(problem, contains('20 s'));
      expect(problem, contains('20412 ms'));
      expect(problem, contains('not raised'));
      expect(problem, contains('Appstein could not finish checking: x'));
    });

    test('has no time for a run that was not timed', () {
      expect(
        terminalCutProblem(fastFlag, 'a sampled run', stdout: '', stderr: ''),
        isNot(contains(' ms')),
      );
    });
  });

  group('countCache', () {
    test('counts the files in the folder and under it as entries, and the '
        '-temp- files of a killed server apart, as half-written', () {
      final folder = Directory.systemTemp.createTempSync('cache entries ');
      addTearDown(() => folder.deleteSync(recursive: true));
      for (final name in [
        '.analysis-driver/00/00a1.resolved2',
        '.analysis-driver/00/00a1.resolved2.digest',
        '.analysis-driver/ff/ffb2.unlinked2',
        '.analysis-driver/0be3.unlinked2-temp-29064',
        '.analysis-driver/11fc.resolved2-temp-7',
        '.instrumentation/log.txt',
      ]) {
        File(p.join(folder.path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      expect(countCache(folder.path), (entries: 4, halfWritten: 2));
    });

    test('is 0 and 0 for a folder that does not exist', () {
      expect(countCache(p.join('no', 'such', 'folder')), (
        entries: 0,
        halfWritten: 0,
      ));
    });
  });

  group('discardCache', () {
    test('deletes the folder and warns of nothing', () {
      final folder = Directory.systemTemp.createTempSync('cold cache ');
      File(p.join(folder.path, 'a', 'b')).createSync(recursive: true);
      final warnings = <String>[];
      discardCache(folder.path, warn: warnings.add);
      expect(folder.existsSync(), isFalse);
      expect(warnings, isEmpty);
    });

    test('warns, and does not throw, when the folder cannot be deleted: '
        'a server on Windows still holds a file', () {
      final warnings = <String>[];
      discardCache(
        'cold cache 3',
        warn: warnings.add,
        delete: (path) => throw FileSystemException(
          'Deletion failed',
          path,
          const OSError('The process cannot access the file', 32),
        ),
      );
      expect(warnings, [
        allOf(
          contains('could not delete the cache folder cold cache 3'),
          contains('The process cannot access the file'),
          contains('goes with the work folder'),
        ),
      ]);
    });

    test('passes on any other error', () {
      expect(
        () => discardCache(
          'x',
          warn: (_) {},
          delete: (_) => throw StateError('a bug'),
        ),
        throwsStateError,
      );
    });

    test('leaves a failed run\'s error to the caller of measureTerminalRows '
        'when its cold cache cannot be deleted', () async {
      final cache = _FakeCache(warmAdds: [100, 0], failCold: 0);
      final warnings = <String>[];
      await expectLater(
        measureTerminalRows(
          run: cache.run,
          warmCache: 'warm',
          newCache: cache.newCache,
          discardCache: (path) => discardCache(
            path,
            warn: warnings.add,
            delete: (path) => throw FileSystemException('held', path),
          ),
          cacheCount: cache.count,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('--fast (a cold run)'),
          ),
        ),
      );
      expect(warnings, [contains('cold 0')]);
    });
  });

  group('roundOrder', () {
    test('alternates which row runs first', () {
      expect(roundOrder(0), [fastFlag, fullFlag]);
      expect(roundOrder(1), [fullFlag, fastFlag]);
      expect(roundOrder(2), [fastFlag, fullFlag]);
    });
  });

  group('measureTerminalRows', () {
    const warmCache = 'warm';

    test('runs a full run first, then cold rounds with a new cache each, a '
        'warm-up until a run adds no file, then warm rounds, in alternating '
        'order', () async {
      final cache = _FakeCache(
        // The warm cache: the first run, then a warm-up whose times pause
        // (7000, 7000) and then keep falling while files are added: it
        // goes on past the pause until a run adds none.
        warmAdds: [100, 50, 40, 30, 20, 0],
        warmTimes: [9000, 8000, 7000, 7000, 5000, 4000, 4000],
      );
      final rows = await measureTerminalRows(
        run: cache.run,
        warmCache: warmCache,
        newCache: cache.newCache,
        discardCache: cache.discard,
        cacheCount: cache.count,
      );
      expect(cache.calls, [
        'full warm',
        'fast cold 0', 'full cold 1', // round 0
        'full cold 2', 'fast cold 3', // round 1
        'fast cold 4', 'full cold 5', // round 2
        for (var i = 0; i < 5; i++) 'full warm', // the warm-up
        'fast warm', 'full warm', 'full warm', 'fast warm', 'fast warm',
        'full warm', // the warm rounds
      ]);
      expect(cache.discarded, [for (var i = 0; i < 6; i++) 'cold $i']);
      expect(rows.warmUp, [
        for (final ms in [8000, 7000, 7000, 5000, 4000])
          Duration(milliseconds: ms),
      ]);
      expect(rows.warmUpAdded, [50, 40, 30, 20, 0]);
      expect(rows.capped, isFalse);
      expect(rows.coldFast, hasLength(3));
      expect(rows.coldFull, hasLength(3));
      expect(rows.coldFast.first, cache.coldTime);
      expect(rows.warmFast, hasLength(3));
      expect(rows.warmFull, hasLength(3));
    });

    test('goes on past a run that added no entry but left half-written '
        'files: its server was killed before it renamed any into place, and '
        'stops at the first run that did neither', () async {
      final cache = _FakeCache(
        // The first run, then the warm-up.
        warmAdds: [100, 30, 0, 0, 0],
        warmHalfWritten: [2, 4, 3, 0, 0],
      );
      final rows = await measureTerminalRows(
        run: cache.run,
        warmCache: warmCache,
        newCache: cache.newCache,
        discardCache: cache.discard,
        cacheCount: cache.count,
      );
      expect(rows.warmUpAdded, [30, 0, 0]);
      expect(rows.warmUpHalfWritten, [4, 3, 0]);
      expect(rows.capped, isFalse);
    });

    test('stops the warm-up at its cap and says so when the cache keeps '
        'growing', () async {
      final cache = _FakeCache(warmAdds: [for (var i = 0; i < 40; i++) 10]);
      final rows = await measureTerminalRows(
        run: cache.run,
        warmCache: warmCache,
        newCache: cache.newCache,
        discardCache: cache.discard,
        cacheCount: cache.count,
        warmUpMost: 4,
      );
      expect(rows.warmUp, hasLength(4));
      expect(rows.warmUpAdded, [10, 10, 10, 10]);
      expect(rows.capped, isTrue);
      expect(rows.warmFast, hasLength(3));
    });

    test('fails when a run does not count, and still discards its cold '
        'cache', () async {
      final cache = _FakeCache(warmAdds: [100, 0], failCold: 1);
      await expectLater(
        measureTerminalRows(
          run: cache.run,
          warmCache: warmCache,
          newCache: cache.newCache,
          discardCache: cache.discard,
          cacheCount: cache.count,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('--full (a cold run)'), contains('exit code 3')),
          ),
        ),
      );
      expect(cache.discarded, ['cold 0', 'cold 1']);
    });

    test('a cold fast run cut by the cap fails the row with the cap, the '
        'time and the output, not as "named checks as not run"; its cold '
        'cache is discarded', () async {
      final discarded = <String>[];
      var cold = 0;
      await expectLater(
        measureTerminalRows(
          run: (flag, cache) async => cache == warmCache
              ? (
                  exitCode: 0,
                  stdout: fullOutput(),
                  stderr: '',
                  elapsed: Duration.zero,
                )
              : (
                  exitCode: 3,
                  stdout:
                      'Not run:\n  dart.error: the code checks of this '
                      'change are still pending\n\n$fastSummary\n',
                  stderr:
                      'Appstein could not finish checking: x. This run '
                      'exits 3\n',
                  elapsed: const Duration(milliseconds: 20300),
                ),
          warmCache: warmCache,
          newCache: () => 'cold ${cold++}',
          discardCache: discarded.add,
          cacheCount: (_) => (entries: 5, halfWritten: 0),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cut by the fast-run cap'),
              contains('20300 ms'),
              contains('verify.fast_timeout_seconds'),
              isNot(contains('named checks as not run')),
            ),
          ),
        ),
      );
      expect(discarded, ['cold 0']);
    });

    test('fails when a run left its cache folder empty: the cache variable '
        'did not reach the server', () async {
      final cache = _FakeCache(warmAdds: [0]);
      await expectLater(
        measureTerminalRows(
          run: cache.run,
          warmCache: warmCache,
          newCache: cache.newCache,
          discardCache: cache.discard,
          cacheCount: cache.count,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(analysisCacheVariable),
          ),
        ),
      );
    });
  });

  group('sampledPeak', () {
    SampledRun sampled(int? peak, {int exitCode = 0}) =>
        (exitCode: exitCode, stdout: '$fastSummary\n', stderr: '', peak: peak);

    test('is the peak of a run that was seen', () async {
      var runs = 0;
      expect(
        await sampledPeak(() async {
          runs++;
          return sampled(900);
        }, flag: fastFlag),
        900,
      );
      expect(runs, 1);
    });

    test('runs once more when the first run was never seen', () async {
      final peaks = [null, 800];
      var runs = 0;
      expect(
        await sampledPeak(() async => sampled(peaks[runs++]), flag: fastFlag),
        800,
      );
      expect(runs, 2);
    });

    test('fails when the second run was never seen either', () async {
      var runs = 0;
      await expectLater(
        sampledPeak(() async {
          runs++;
          return sampled(null);
        }, flag: fastFlag),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('never saw its guard and analysis server, in two runs'),
          ),
        ),
      );
      expect(runs, 2);
    });

    test('a sampled fast run cut by the cap fails with the cap, not as a '
        'run that named checks as not run', () async {
      await expectLater(
        sampledPeak(
          () async => (
            exitCode: 3,
            stdout: 'Not run:\n  dart.error: still pending\n',
            stderr: 'Appstein could not finish checking: x\n',
            peak: 900,
          ),
          flag: fastFlag,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cut by the fast-run cap'),
              contains('a sampled run'),
            ),
          ),
        ),
      );
    });

    test('checks the output of a sampled run', () async {
      await expectLater(
        sampledPeak(() async => sampled(900, exitCode: 1), flag: fastFlag),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('a sampled run'), contains('exit code 1')),
          ),
        ),
      );
    });
  });
}

/// A fake of the analysis server's cache folders and of `appstein verify`
/// runs on the measured app: each run adds files to the folder it is given
/// and records itself in [calls].
final class _FakeCache {
  _FakeCache({
    required this.warmAdds,
    this.warmHalfWritten = const [0],
    this.warmTimes = const [],
    this.failCold,
  });

  /// How many cache entries each run on the warm cache adds, in order; the
  /// last number repeats.
  final List<int> warmAdds;

  /// How many half-written files each run on the warm cache leaves, in
  /// order; the last number repeats.
  final List<int> warmHalfWritten;

  /// The time of each run on the warm cache, in order; the last repeats,
  /// and 1 s when empty.
  final List<int> warmTimes;

  /// The cold run, by its number, that exits 3.
  final int? failCold;

  /// The time of every cold run.
  final coldTime = const Duration(seconds: 12);

  final calls = <String>[];
  final discarded = <String>[];
  final _files = <String, int>{};
  final _halfWritten = <String, int>{};
  var _cold = 0;
  var _warmRuns = 0;

  String newCache() {
    final name = 'cold ${_cold++}';
    _files[name] = 0;
    return name;
  }

  void discard(String cache) {
    discarded.add(cache);
    _files.remove(cache);
  }

  CacheCount count(String cache) =>
      (entries: _files[cache] ?? 0, halfWritten: _halfWritten[cache] ?? 0);

  static int _nth(List<int> numbers, int n) =>
      numbers[n < numbers.length ? n : numbers.length - 1];

  Future<CommandRun> run(String flag, String cache) async {
    final kind = flag == fastFlag ? 'fast' : 'full';
    final Duration elapsed;
    if (cache == 'warm') {
      calls.add('$kind warm');
      final n = _warmRuns++;
      _files['warm'] = (_files['warm'] ?? 0) + _nth(warmAdds, n);
      _halfWritten['warm'] =
          (_halfWritten['warm'] ?? 0) + _nth(warmHalfWritten, n);
      elapsed = Duration(
        milliseconds: warmTimes.isEmpty
            ? 1000
            : warmTimes[n < warmTimes.length ? n : warmTimes.length - 1],
      );
    } else {
      calls.add('$kind $cache');
      _files[cache] = 2400;
      elapsed = coldTime;
    }
    final failed = cache == 'cold $failCold';
    return (
      exitCode: failed ? 3 : 0,
      stdout: flag == fastFlag ? '$fastSummary\n' : fullOutput(),
      stderr: '',
      elapsed: elapsed,
    );
  }
}
