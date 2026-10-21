@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../analysis/support/analysis_support.dart';
import '../support/fixture_app.dart';
import '../support/flutter_test_output.dart';
import '../support/machine_sdk.dart';
import '../support/temp.dart';

/// One process of the machine: its ID, its parent's and its name.
typedef _Running = ({int id, int parent, String name});

/// Every process running now. It only reads the list.
Future<List<_Running>> _processes() async {
  final listed = Platform.isWindows
      ? await Process.run('powershell.exe', const [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Get-CimInstance Win32_Process | ForEach-Object '
              '{ "\$(\$_.ProcessId) \$(\$_.ParentProcessId) \$(\$_.Name)" }',
        ])
      : await Process.run('ps', const ['-A', '-o', 'pid=,ppid=,comm=']);
  return [
    for (final line in '${listed.stdout}'.split('\n'))
      if (RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+?)\s*$').firstMatch(line)
          case final match?)
        (
          id: int.parse(match[1]!),
          parent: int.parse(match[2]!),
          name: match[3]!,
        ),
  ];
}

/// The real process runner, keeping what its last run printed.
final class _Recording implements ProcessRunner {
  RunResult? last;

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
    String? workingDirectory,
  }) async => last = await const SystemProcessRunner().run(
    executable,
    arguments,
    timeout: timeout,
    environment: environment,
    workingDirectory: workingDirectory,
  );
}

/// The last [count] events in [stdout], each cut at 400 characters, with
/// the paths of [app], of the Flutter SDK at [flutter] and of the home
/// folder written as `{app}`, `{flutter}` and `~`: a failing CI run shows
/// the real sequence, and no path outside the temp project.
String _lastEvents(
  String stdout, {
  required String app,
  required String flutter,
  int count = 30,
}) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  String plain(String line) {
    for (final (path, name) in [
      (app, '{app}'),
      (flutter, '{flutter}'),
      if (home != null && home.length > 3) (home, '~'),
    ]) {
      final slashed = path.replaceAll(r'\', '/');
      for (final form in {
        Uri.file(path).toString(),
        Uri.decodeFull(Uri.file(path).toString()),
        slashed,
        path,
        path.replaceAll(r'\', r'\\'),
      }) {
        line = line.replaceAll(form, name);
      }
    }
    return line.length > 400 ? '${line.substring(0, 400)}…' : line;
  }

  final events = [
    for (final line in stdout.split('\n'))
      if (line.trimLeft().startsWith('{')) plain(line.trim()),
  ];
  return events
      .skip(events.length > count ? events.length - count : 0)
      .join('\n');
}

/// The failures of [tests], each with its file, line and details, and
/// [printed] (the last events), as the reason of an expectation. It is built
/// before the expectation, not when it fails: `expect` takes the reason as a
/// string, and building it costs next to nothing.
String _failureReason(TestRun tests, String printed) => [
  for (final failure in tests.failures)
    '${failure.file}:${failure.line} ${failure.test ?? '(loading)'}'
        '${failure.afterLoading ? ' (reported after it loaded)' : ''}: '
        '${failure.details}',
  'The last events:',
  printed,
].join('\n');

// The real `flutter test` of this machine's Flutter SDK (slice 1d.2). The
// scripted tests in `test/verify/` use output copied from the first run
// here, so this test is also what keeps that copy true.
void main() {
  final machine = HostEnvironment.current();

  /// The `tests_app` fixture in a temp folder whose name has a space,
  /// without its `test/` folder when [tests] is false, its packages fetched
  /// with the SDK at [flutterRoot].
  Future<String> testsApp(String flutterRoot, {bool tests = true}) async {
    final app = p.join(tempDir().path, 'tests app');
    copyFixtureTree(p.join(fixtureAppsDir, 'tests_app'), app);
    if (!tests) Directory(p.join(app, 'test')).deleteSync(recursive: true);
    final problem = await fetchPackages(
      app,
      flutterRoot: flutterRoot,
      os: machine.os,
      runner: const SystemProcessRunner(),
    );
    expect(problem, isNull);
    return app;
  }

  /// The machine, with [flutterRoot] as the Flutter SDK a project without a
  /// pin uses.
  HostEnvironment using(String flutterRoot) => HostEnvironment(
    os: machine.os,
    variables: {...machine.variables, 'FLUTTER_ROOT': flutterRoot},
    workingDirectory: machine.workingDirectory,
  );

  test('the fixture app\'s tests: each failing test and the file that '
      'can\'t load, as the scripted output says', () async {
    final sdk = machineSdk(machine);
    if (sdk == null) return;
    final root = sdk.location!.root;
    final app = await testsApp(root);

    final recording = _Recording();
    final tests = await runProjectTests(
      projectRoot: app,
      environment: using(root),
      runner: recording,
      timeout: const Duration(minutes: 8),
    );

    // What `flutter test` printed last: a failing run shows the real
    // sequence of events. An error on a file after it loaded was seen once,
    // on Linux CI, with its text not recorded: the next one is printed
    // below, so its text is in the log.
    final printed = _lastEvents(
      recording.last?.stdout ?? '',
      app: app,
      flutter: root,
    );
    final reason = _failureReason(tests, printed);
    expect((tests.ran, tests.timedOut), (true, false), reason: reason);
    // `flutter test` can report an error on a file after it loaded (the
    // likely cause is the shutdown error of its test process): a finding of
    // its own, which says nothing against the file's tests.
    if (tests.failures.any((failure) => failure.afterLoading)) {
      print('An error after a file loaded was accepted:\n$reason');
    }
    for (final failure in tests.failures.where((one) => one.afterLoading)) {
      expect(failure.test, isNull, reason: reason);
      expect(
        failure.file,
        isNot('test/broken_test.dart'),
        reason: 'a file that did not load has no tests that ran\n$reason',
      );
    }
    final failures = [
      for (final failure in tests.failures)
        if (!failure.afterLoading) failure,
    ];
    final told = {
      for (final failure in failures)
        (failure.file, failure.test): (failure.line, failure.details),
    };
    expect(told.keys, hasLength(failures.length), reason: reason);
    expect(told.keys.toSet(), {
      ('test/broken_test.dart', null),
      ('test/my folder/spaced_test.dart', 'in a folder with a space'),
      ('test/my folder/spaced_test.dart', 'a widget in a folder with a space'),
      ('test/widgets/failing_test.dart', 'counter next adds two'),
      ('test/widgets/failing_test.dart', 'counter next throws'),
      ('test/widgets/failing_test.dart', 'shows other text'),
      ('test/widgets/failing_test.dart', 'widget throws'),
    }, reason: reason);
    expect(told[('test/widgets/failing_test.dart', 'counter next adds two')], (
      8,
      'Expected: <3> Actual: <2>',
    ));
    expect(told[('test/widgets/failing_test.dart', 'counter next throws')], (
      12,
      'Bad state: the counter broke',
    ));
    expect(told[('test/widgets/failing_test.dart', 'shows other text')], (
      18,
      'The following TestFailure was thrown running a test: '
          'Expected: exactly one matching candidate '
          'Actual: _TextWidgetFinder:<Found 0 widgets with text '
          '"goodbye": []> '
          'Which: means none were found but one was expected',
    ));
    expect(told[('test/widgets/failing_test.dart', 'widget throws')], (
      28,
      'The following ArgumentError was thrown running a test: '
          'Invalid argument(s): bad widget',
    ));
    final (brokenLine, broken) = told[('test/broken_test.dart', null)]!;
    expect(brokenLine, isNull);
    expect(
      broken,
      allOf(
        startsWith('Compilation failed for testPath=test/broken_test.dart: '),
        contains('Method not found: \'nextt\''),
      ),
    );
    // Flutter 3.47.5 on Windows gives no line for a test whose path from
    // the project has a space. Where it gives one, it is the test's.
    final (spacedLine, spaced) =
        told[('test/my folder/spaced_test.dart', 'in a folder with a space')]!;
    expect(spacedLine, anyOf(isNull, 6));
    expect(spaced, 'Expected: <6> Actual: <5>');
    final (widgetLine, _) =
        told[(
          'test/my folder/spaced_test.dart',
          'a widget in a folder with a space',
        )]!;
    expect(widgetLine, anyOf(isNull, 10));
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('the passing test alone: no failure', () async {
    final sdk = machineSdk(machine);
    if (sdk == null) return;
    final root = sdk.location!.root;
    final app = await testsApp(root);
    File(p.join(app, 'test', 'broken_test.dart')).deleteSync();
    Directory(p.join(app, 'test', 'my folder')).deleteSync(recursive: true);
    Directory(p.join(app, 'test', 'widgets')).deleteSync(recursive: true);

    final recording = _Recording();
    final tests = await runProjectTests(
      projectRoot: app,
      environment: using(root),
      runner: recording,
      timeout: const Duration(minutes: 8),
    );
    final reason = _failureReason(
      tests,
      _lastEvents(recording.last?.stdout ?? '', app: app, flutter: root),
    );
    expect((tests.ran, tests.timedOut), (true, false), reason: reason);
    // Only an error on the file after it loaded is accepted (see the test of
    // the whole fixture app): no failing test, no file that can't load.
    if (tests.failures.any((failure) => failure.afterLoading)) {
      print('An error after a file loaded was accepted:\n$reason');
    }
    expect(
      [
        for (final failure in tests.failures)
          if (!failure.afterLoading || failure.test != null) failure.details,
      ],
      isEmpty,
      reason: reason,
    );
    expect(flutterTestCommand, flutterTestArguments);
  }, timeout: const Timeout(Duration(minutes: 15)));

  // `flutter` is a `.bat` file on Windows: ending it alone would leave the
  // Flutter tool, its compiler and the test process running.
  test('a test that never ends: the run is stopped at the limit, and no '
      'process it started is left running', () async {
    final sdk = machineSdk(machine);
    if (sdk == null) return;
    final root = sdk.location!.root;
    final app = await testsApp(root, tests: false);
    // The test says which process runs it, then waits for ever.
    final sign = File(p.join(app, 'hanging.pid'));
    File(p.join(app, 'test', 'hanging_test.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('never ends', () async {
    File(r'${sign.path}').writeAsStringSync('\$pid');
    await Completer<void>().future;
  }, timeout: Timeout.none);
}
''');

    const limit = Duration(seconds: 75);
    final watch = Stopwatch()..start();
    final recording = _Recording();
    final running = runProjectTests(
      projectRoot: app,
      environment: using(root),
      runner: recording,
      timeout: limit,
    );
    while (!sign.existsSync() || sign.readAsStringSync().isEmpty) {
      if (watch.elapsed > limit - const Duration(seconds: 10)) {
        await running;
        fail(
          'The hanging test had not started ${watch.elapsed.inSeconds} s '
          'into a limit of ${limit.inSeconds} s: this machine was too slow '
          'for the test to show anything.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final tester = int.parse(sign.readAsStringSync());
    final startedAfter = watch.elapsed;

    // The processes `flutter test` consists of: from the test's own process
    // up to the one this test started, and everything below that one.
    final all = await _processes();
    _Running? of(int id) => all.where((one) => one.id == id).firstOrNull;
    var top = of(tester);
    expect(top, isNotNull, reason: 'the hanging test process $tester');
    final chain = [top!];
    while (top!.parent != pid) {
      top = of(top.parent);
      if (top == null) {
        fail(
          'The test process is not below this one any more: '
          '${chain.map((one) => '${one.name} ${one.id}').join(' < ')}',
        );
      }
      chain.add(top);
    }
    final tree = <_Running>[top];
    for (var index = 0; index < tree.length; index++) {
      tree.addAll(all.where((one) => one.parent == tree[index].id));
    }
    expect(tree.map((one) => one.id), contains(tester));
    // Whatever this test finds: it leaves none of the processes it started.
    addTearDown(() async {
      for (final one in tree) {
        if (await processAlive(one.id)) Process.killPid(one.id);
      }
    });
    for (final one in tree) {
      expect(await processAlive(one.id), isTrue, reason: '$one before');
    }

    final tests = await running;
    final stoppedAfter = watch.elapsed;
    // What `flutter test` printed last, so a failing CI run shows the real
    // sequence of events.
    final printed = _lastEvents(
      recording.last?.stdout ?? '',
      app: app,
      flutter: root,
    );
    expect(
      (tests.ran, tests.timedOut),
      (true, true),
      reason: 'The last events:\n$printed',
    );
    expect(
      tests.failures,
      isEmpty,
      // What the run read as failures, so a failing CI run shows the event.
      reason: [
        for (final failure in tests.failures)
          '${failure.file}:${failure.line} '
              '${failure.test ?? '(loading)'}: ${failure.details}',
        'The last events:',
        printed,
      ].join('\n'),
    );
    // What the run had printed is kept: it names the test that never ended.
    expect(tests.running, [
      (file: 'test/hanging_test.dart', test: 'never ends'),
    ], reason: 'The last events:\n$printed');
    expect(stoppedAfter, greaterThanOrEqualTo(limit));

    final gone = await goneWithin([
      for (final one in tree) one.id,
    ], const Duration(seconds: 10));
    // Kept in the test's output as the record of what was ended.
    print(
      'flutter test: the test started after ${startedAfter.inSeconds} s; '
      'stopped after ${stoppedAfter.inMilliseconds} ms (limit '
      '${limit.inSeconds} s); ${tree.length} processes '
      '(${tree.map((one) => '${one.name} ${one.id}').join(', ')}) '
      '${gone == null ? 'NOT all gone' : 'gone ${gone.inMilliseconds} ms '
                'after the run returned'}',
    );
    expect(
      gone,
      isNotNull,
      reason:
          'still running: '
          '${[for (final one in tree)
            if (await processAlive(one.id)) '${one.name} ${one.id}']}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
