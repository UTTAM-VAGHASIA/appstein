import 'dart:async';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';
import 'support/analysis_support.dart';

/// The timers a kept server asked for. A test fires the idle timer itself,
/// so no outcome depends on how fast the machine is.
final class _Timers {
  final made = <_Timer>[];

  Timer call(Duration time, void Function() then) {
    final timer = _Timer(time, then);
    made.add(timer);
    return timer;
  }

  /// The timers that were neither cancelled nor fired.
  List<_Timer> get waiting => [
    for (final timer in made)
      if (timer.isActive) timer,
  ];

  /// Fires the one timer that is waiting, as the idle time ending does.
  void fire() => waiting.single.fire();
}

final class _Timer implements Timer {
  _Timer(this.time, this._then);

  final Duration time;
  final void Function() _then;

  @override
  bool isActive = true;

  @override
  int get tick => 0;

  @override
  void cancel() => isActive = false;

  void fire() {
    isActive = false;
    _then();
  }
}

/// A stand-in for an analysis server whose start and stop a test holds
/// back and lets go: it starts no process.
final class _Server implements StoppableCodeAnalysis {
  /// What happened, in order.
  final log = <String>[];

  var running = false;
  var closed = false;

  /// When set, a start waits for it.
  Completer<void>? starting;

  /// When set, a stop waits for it.
  Completer<void>? stopping;

  int get starts => log.where((line) => line == 'started').length;

  @override
  Future<CodeReading> read() async {
    if (closed) throw StateError('asked after it was closed');
    if (!running) {
      log.add('start begins');
      await starting?.future;
      if (closed) throw const CodeAnalysisException('it was stopped');
      running = true;
      log.add('started');
    }
    return const CodeReading();
  }

  @override
  Future<void> stop() async {
    if (!running) return;
    log.add('stop begins');
    await stopping?.future;
    running = false;
    log.add('stopped');
  }

  @override
  Future<void> close() {
    closed = true;
    // A start that is waiting is let go, and fails.
    if (starting case final waiting? when !waiting.isCompleted) {
      waiting.complete();
    }
    return stop();
  }
}

/// Lets everything that can run without a timer or a completer run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// A use of [kept] that reads and returns the server's processes, having
/// seen both running. It looks inside the use, where the idle time doesn't
/// run.
Future<({int guard, int server})> readRunning(
  KeptAnalysisServer<AnalysisServer> kept,
) => kept.use((analysis) async {
  await analysis.read();
  final processes = kept.server.processes!;
  await recordProcesses([processes.guard, processes.server]);
  expect(await processAlive(processes.guard), isTrue);
  expect(await processAlive(processes.server), isTrue);
  return processes;
});

// An analysis server kept between uses (slice 1d.2, ticket 04): started by
// the first use, shared by the uses in turn, stopped when idle and when its
// owner closes it. The stand-in and the timers above make every order of
// events one the test sets; two tests at the end use real processes.
void main() {
  test('the idle time is ten minutes, counted by a real timer unless one is '
      'given', () {
    expect(analysisIdleStop, const Duration(minutes: 10));
    final kept = KeptAnalysisServer(realAnalysisServer(tempDir().path));
    addTearDown(kept.close);
    expect(kept.idleStop, analysisIdleStop);
  });

  group('with a stand-in server and timers the test fires', () {
    late _Server server;
    late _Timers timers;
    late KeptAnalysisServer<_Server> kept;

    setUp(() {
      server = _Server();
      timers = _Timers();
      kept = KeptAnalysisServer(server, newTimer: timers.call);
    });

    Future<void> read() => kept.use((analysis) => analysis.read());

    test('nothing is started until a use asks; the server stays after the '
        'use; when the idle time ends it is stopped, and the next use '
        'starts it again', () async {
      expect(server.log, isEmpty);
      await kept.use((analysis) async {});
      expect(server.log, isEmpty, reason: 'a use that asks nothing');

      await read();
      expect(server.log, ['start begins', 'started']);
      expect(server.running, isTrue);
      expect(timers.waiting.single.time, analysisIdleStop);

      timers.fire();
      await settle();
      expect(server.log, ['start begins', 'started', 'stop begins', 'stopped']);
      expect(timers.waiting, isEmpty);

      await read();
      expect(server.starts, 2);
      expect(server.running, isTrue);
    });

    test('the idle time never runs while the server is starting or a use '
        'is being answered: its timer is made only when the use '
        'ends', () async {
      await read();
      expect(timers.waiting, hasLength(1));

      // A use during which the server must start again.
      await server.stop();
      server.starting = Completer();
      final leave = Completer<void>();
      final using = kept.use((analysis) async {
        await analysis.read();
        await leave.future;
      });
      await settle();
      expect(server.log.last, 'start begins');
      expect(timers.waiting, isEmpty, reason: 'while the server starts');

      server.starting!.complete();
      await settle();
      expect(server.running, isTrue);
      expect(timers.waiting, isEmpty, reason: 'while the use is answered');

      leave.complete();
      await using;
      expect(timers.waiting, hasLength(1));
    });

    test('each use starts the idle time again: the timer of the use before '
        'is cancelled', () async {
      await read();
      final first = timers.waiting.single;
      await read();
      await read();
      expect(first.isActive, isFalse);
      expect(timers.made, hasLength(3));
      expect(timers.waiting, [timers.made.last]);
      expect(server.starts, 1);
    });

    test('uses that arrive while the server is starting, or while another '
        'use is answered, wait their turn, and all share one '
        'server', () async {
      server.starting = Completer();
      final order = <String>[];
      final leave = <String, Completer<void>>{};
      Future<void> use(String name) => kept.use((analysis) async {
        order.add('$name begins');
        await analysis.read();
        await (leave[name] = Completer<void>()).future;
        order.add('$name ends');
      });

      final all = [use('first'), use('second'), use('third')];
      await settle();
      expect(order, ['first begins']);
      expect(server.log, ['start begins']);

      server.starting!.complete();
      await settle();
      // The server is running; the first use is still being answered.
      expect(order, ['first begins']);
      leave['first']!.complete();
      await settle();
      expect(order, ['first begins', 'first ends', 'second begins']);
      leave['second']!.complete();
      await settle();
      leave['third']!.complete();
      await Future.wait(all);
      expect(order, [
        'first begins',
        'first ends',
        'second begins',
        'second ends',
        'third begins',
        'third ends',
      ]);
      expect(server.starts, 1);
    });

    test('a use that arrives while the idle server is being stopped waits '
        'for the stop to end, and then starts a new server', () async {
      await read();
      server.stopping = Completer();
      timers.fire();
      await settle();
      expect(server.log.last, 'stop begins');

      var answered = false;
      final using = read().then((_) => answered = true);
      await settle();
      expect(answered, isFalse);
      expect(server.log.last, 'stop begins', reason: 'no start during a stop');

      server.stopping!.complete();
      await using;
      expect(server.log, [
        'start begins',
        'started',
        'stop begins',
        'stopped',
        'start begins',
        'started',
      ]);
    });

    test('a use whose body fails leaves the server running for the next '
        'one, and starts the idle time', () async {
      await expectLater(
        kept.use<void>((analysis) async {
          await analysis.read();
          throw StateError('the body failed');
        }),
        throwsStateError,
      );
      expect(server.running, isTrue);
      expect(timers.waiting, hasLength(1));
      await read();
      expect(server.starts, 1);
    });

    test('close returns only when an idle stop that was under way has '
        'ended', () async {
      await read();
      server.stopping = Completer();
      timers.fire();
      await settle();
      expect(server.log.last, 'stop begins');

      var closed = false;
      final closing = kept.close().then((_) => closed = true);
      await settle();
      await settle();
      expect(closed, isFalse, reason: 'the server has not ended yet');

      server.stopping!.complete();
      await closing;
      expect(server.running, isFalse);
      expect(server.log.last, 'stopped');
    });

    test('a use that loses to a close, while it waits for its turn or '
        'afterwards, fails as an analysis that can\'t answer, with a reason '
        'that says why; nothing is started', () async {
      await read();
      server.stopping = Completer();
      timers.fire();
      await settle();
      // Waiting behind the idle stop when the close comes.
      final waiting = expectLater(
        read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => '$error',
            'text',
            'The Dart analysis server could not answer: it was closed, '
                'because Appstein is stopping.',
          ),
        ),
      );
      final closing = kept.close();
      server.stopping!.complete();
      await closing;
      await waiting;
      await expectLater(read(), throwsA(isA<CodeAnalysisException>()));
      expect(server.starts, 1);
      expect(timers.waiting, isEmpty);
    });

    test('close while a use waits for the server to start: the use fails, '
        'and close returns when the use has ended', () async {
      server.starting = Completer();
      final using = expectLater(read(), throwsA(isA<CodeAnalysisException>()));
      await settle();
      expect(server.log, ['start begins']);
      await kept.close();
      await using;
      expect(server.running, isFalse);
      expect(timers.waiting, isEmpty);
    });
  });

  test('a scripted server process: close stops it at once, also while a use '
      'waits for it; a later use is refused', () async {
    final kept = KeptAnalysisServer(
      AnalysisServer(
        projectRoot: tempDir().path,
        guardCommand: [
          Platform.resolvedExecutable,
          analysisSupportFile('fake_server_guard.dart'),
          // Never done: the use can only end by the close, however slow
          // the machine is.
          'never',
        ],
        dartExecutable: () => testDart,
      ),
    );
    addTearDown(kept.close);
    final waiting = kept.use((analysis) => analysis.read());
    final failed = expectLater(
      waiting,
      throwsA(
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          'it was stopped',
        ),
      ),
    );
    // Until the guard has named itself; its analysis is never done.
    ({int guard, int server})? processes;
    for (var i = 0; i < 200 && processes == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      processes = kept.server.processes;
    }
    expect(processes, isNotNull, reason: 'the guard never named itself');
    await recordProcesses([processes!.guard]);
    await kept.close();
    await failed;
    // Close returned only after the process had ended.
    expect(await processAlive(processes.guard), isFalse);
    await expectLater(
      kept.use((analysis) => analysis.read()),
      throwsA(isA<CodeAnalysisException>()),
    );
    expect(kept.server.processes, isNull);
  });

  test('a real server: stopped with its guard when the idle time ends, and '
      'started again by the next use, which reports what changed '
      'meanwhile', () async {
    final app = copyFixtureApp();
    writeProjectFile(
      app,
      'lib/broken.dart',
      '/// Wrong on purpose.\nint wrong() => \'text\';\n',
    );
    final timers = _Timers();
    final kept = KeptAnalysisServer(
      realAnalysisServer(app),
      newTimer: timers.call,
    );
    addTearDown(kept.close);
    Future<List<String>> broken() => kept.use(
      (analysis) async => [
        for (final found in (await analysis.read()).diagnostics)
          if (found.file == 'lib/broken.dart') found.code,
      ],
    );

    expect(await broken(), ['return_of_invalid_type']);
    final (:guard, :server) = await readRunning(kept);

    // The idle time ends. The next use waits for the stop, so when it is
    // answered the first server and its guard have ended.
    timers.fire();
    writeProjectFile(app, 'lib/broken.dart', '/// Right.\nint right = 1;\n');
    expect(await broken(), isEmpty);
    expect(await processAlive(guard), isFalse, reason: 'the idle guard');
    expect(await processAlive(server), isFalse, reason: 'the idle server');
    final again = await readRunning(kept);

    await kept.close();
    expect(await processAlive(again.guard), isFalse);
    expect(await processAlive(again.server), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
