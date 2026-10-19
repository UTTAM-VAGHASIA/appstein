import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_cli/src/verify_hook.dart'
    show HookAnswer, claudeHookKind, hookInputLimit, hookKindOf;
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';
import 'support/healthy_project.dart';
import 'support/scripted_code_analysis.dart';

/// A check that reports what it was given, in a fast run.
final class _Reports implements VerifyCheck {
  const _Reports(this.findings, {this.ids = const ['x.check']});

  final List<Finding> findings;

  @override
  final List<String> ids;

  @override
  bool get needsMap => false;

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  Future<List<Finding>> run(VerifyContext context) async => findings;
}

/// A fast check that finds nothing and counts how often it ran: a run that
/// stayed silent ran no check.
final class _Counting implements VerifyCheck {
  /// How often the check ran.
  int runs = 0;

  @override
  List<String> get ids => const ['x.count'];

  @override
  bool get needsMap => false;

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    runs++;
    return const [];
  }
}

/// A fast check that finds nothing and calls [onRun] each time it runs.
final class _NotifyingCheck implements VerifyCheck {
  _NotifyingCheck(this.onRun);

  final void Function() onRun;

  @override
  List<String> get ids => const ['x.notify'];

  @override
  bool get needsMap => false;

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    onRun();
    return const [];
  }
}

/// A fast check that finds nothing and, the first time it runs, rewrites
/// [file] with [text]: the project changes while the checks run.
final class _EditsWhileRunning implements VerifyCheck {
  _EditsWhileRunning(this.file, this.text);

  final File file;
  final String text;

  /// How often the check ran.
  int runs = 0;

  @override
  List<String> get ids => const ['x.edits'];

  @override
  bool get needsMap => false;

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    if (runs++ == 0) file.writeAsStringSync(text);
    return const [];
  }
}

/// A fast check that reports an error in each unverified Dart file whose text
/// has `BROKEN` in it, and counts how often it ran.
final class _FindsBroken implements VerifyCheck {
  /// How often the check ran.
  int runs = 0;

  @override
  List<String> get ids => const ['x.broken'];

  @override
  bool get needsMap => false;

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    runs++;
    return [
      for (final file in context.unverified.files)
        if (File(
          p.joinAll([context.projectRoot, ...file.split('/')]),
        ).readAsStringSync().contains('BROKEN'))
          Finding(
            id: 'x.broken',
            severity: Severity.error,
            file: file,
            line: 1,
            message: 'The file has BROKEN in it.',
          ),
    ];
  }
}

/// A check that throws, as a broken check of a pack would.
final class _Throws implements VerifyCheck {
  const _Throws();

  @override
  List<String> get ids => const ['boom.check'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) =>
      throw StateError('it broke');
}

Finding _finding(
  String id,
  Severity severity,
  String file, {
  int? line,
  String? message,
  String? fix,
  String? ref,
}) => Finding(
  id: id,
  severity: severity,
  file: file,
  line: line,
  message: message ?? 'Message of $id.',
  fixHint: fix,
  knowledgeRef: ref,
);

/// The `session_id` and event Claude Code gives a PostToolUse hook.
const _claudeInput =
    '{"session_id":"abc123","hook_event_name":"PostToolUse",'
    '"tool_name":"Write","cwd":"/x"}';

void main() {
  group('parseHookInput', () {
    test('reads the session ID and the event name of Claude Code\'s '
        'input', () {
      final input = parseHookInput(_claudeInput);
      expect(input.sessionId, 'abc123');
      expect(input.eventName, 'PostToolUse');
    });

    test('input that is empty, not JSON, not an object, or has fields of '
        'another type counts as no session', () {
      for (final text in [
        '',
        '   \n',
        'not json',
        '{"session_id": ',
        '[1, 2]',
        '"s"',
        'null',
        '{}',
        '{"session_id": 5, "hook_event_name": false}',
        '{"session_id": ""}',
      ]) {
        final input = parseHookInput(text);
        expect(input.sessionId, isNull, reason: text);
        expect(input.eventName, isNull, reason: text);
      }
    });

    test('a byte order mark before the JSON, as a Windows pipe may add, is '
        'ignored', () {
      final input = parseHookInput(
        '${String.fromCharCode(0xFEFF)}{"session_id":"s1"}',
      );
      expect(input.sessionId, 's1');
    });

    test('reads whether the agent is already continuing because of a Stop '
        'hook: only the JSON true is yes, and missing is no', () {
      expect(parseHookInput(_claudeInput).stopHookActive, isFalse);
      expect(parseHookInput('{"stop_hook_active":true}').stopHookActive, true);
      expect(
        parseHookInput('{"stop_hook_active":false}').stopHookActive,
        false,
      );
      for (final text in [
        '',
        'not json',
        '[true]',
        '{"stop_hook_active":"true"}',
        '{"stop_hook_active":1}',
        '{"stop_hook_active":null}',
      ]) {
        expect(parseHookInput(text).stopHookActive, isFalse, reason: text);
      }
    });
  });

  group('appstein verify --hook', () {
    late StringBuffer out;
    late StringBuffer err;
    late Directory work;
    late String project;
    late String sdk;
    late String cache;

    setUp(() async {
      out = StringBuffer();
      err = StringBuffer();
      work = Directory.systemTemp.createTempSync('appstein hook tëst ');
      addTearDown(() => work.deleteSync(recursive: true));
      project = p.join(work.path, 'my app');
      Directory(project).createSync();
      File(
        p.join(project, 'pubspec.yaml'),
      ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
      sdk = createFakeFlutterSdk(p.join(work.path, 'flutter'));
      cache = testAnalysisCache();
      // A healthy project: the only findings are the ones a test adds.
      await createHealthyProject(project: project, sdk: sdk);
    });

    var nextSessionNumber = 0;

    /// Runs `appstein verify --fast --hook claude` (plus [extra]) with the
    /// hook input [input], and the fast checks [checks] when given. Without
    /// an [input] every call is a new session's first run, which always
    /// checks: a run of a session that has run before, with nothing changed,
    /// is silent (the tests of that pass the input).
    Future<int> hook({
      String? input,
      List<String> extra = const [],
      List<VerifyCheck>? checks,
      ScriptedCodeAnalysis? analysis,
      CodeAnalysisScope? scope,
      List<String>? arguments,
      String? workingDirectory,
      Future<String> Function()? readInput,
    }) => runAppstein(
      arguments ?? ['verify', '--fast', '--hook', 'claude', ...extra],
      out: out,
      err: err,
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': sdk, analysisCacheVariable: cache},
        workingDirectory: workingDirectory ?? project,
      ),
      codeAnalysis: scope ?? (analysis ?? ScriptedCodeAnalysis()).scope,
      dartSdkPath: testDartSdk,
      verifyChecks: checks == null
          ? null
          : (_) => [for (final check in checks) (check: check, pack: null)],
      hookInput:
          readInput ??
          () async =>
              input ??
              _claudeInput.replaceFirst(
                'abc123',
                'new-session-${++nextSessionNumber}',
              ),
    );

    Map<String, Object?> stdoutJson() =>
        jsonDecode(out.toString()) as Map<String, Object?>;

    String context() =>
        ((stdoutJson()['hookSpecificOutput']!
                as Map<String, Object?>)['additionalContext'])!
            as String;

    group('refuses', () {
      test(
        '--hook codex, with exit 3, saying its hooks come in slice 1e',
        () async {
          final analysis = ScriptedCodeAnalysis();
          expect(
            await hook(
              arguments: ['verify', '--fast', '--hook', 'codex'],
              analysis: analysis,
            ),
            ExitCodes.appsteinFailed,
          );
          expect(out.toString(), isEmpty);
          expect(err.toString(), contains('Codex'));
          expect(err.toString(), contains('slice 1e'));
          // Nothing was checked.
          expect(analysis.asked, 0);
        },
      );

      test('--hook with --format, with exit 3', () async {
        for (final format in ['text', 'json']) {
          err.clear();
          expect(
            await hook(
              arguments: [
                'verify',
                '--fast',
                '--hook',
                'claude',
                '--format',
                format,
              ],
            ),
            ExitCodes.appsteinFailed,
          );
          expect(out.toString(), isEmpty);
          expect(err.toString(), contains('--format'));
          expect(err.toString(), contains('--hook'));
        }
      });

      test(
        '--hook claude with --fast and --full together, with exit 3',
        () async {
          expect(
            await hook(
              arguments: ['verify', '--fast', '--full', '--hook', 'claude'],
            ),
            ExitCodes.appsteinFailed,
          );
          expect(out.toString(), isEmpty);
          expect(err.toString(), contains('--fast or --full'));
        },
      );

      test('--hook claude --fast --apply, with exit 3: a fast run never '
          'rewrites files', () async {
        expect(
          await hook(
            arguments: ['verify', '--fast', '--apply', '--hook', 'claude'],
          ),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('--apply works with a full run only'));
      });
    });

    group('errors', () {
      test('exit 2; stderr lists the errors only, grouped by file, with the '
          'fix hint and the knowledge reference; stdout is empty', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  _finding(
                    'x.one',
                    Severity.error,
                    'lib/b.dart',
                    line: 3,
                    message: 'Broken b.',
                    fix: 'Fix b.',
                    ref: '.appstein/map/routes.json#home',
                  ),
                  _finding(
                    'x.two',
                    Severity.error,
                    'lib/a.dart',
                    line: 9,
                    message: 'Broken a.',
                  ),
                  _finding(
                    'x.three',
                    Severity.warning,
                    'lib/c.dart',
                    message: 'Only a warning.',
                    fix: 'Not shown.',
                  ),
                  _finding('x.four', Severity.info, 'lib/d.dart'),
                ],
                ids: ['x.one', 'x.two', 'x.three', 'x.four'],
              ),
            ],
          ),
          2,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          'lib/a.dart\n'
          '  error x.two (line 9): Broken a.\n'
          '\n'
          'lib/b.dart\n'
          '  error x.one (line 3): Broken b.\n'
          '    fix: Fix b.\n'
          '    knowledge: .appstein/map/routes.json#home\n',
        );
      });

      test('more than 30 are cut to the first 30 and say how many more and '
          'how to see them all; exactly 30 are not cut', () async {
        List<Finding> errors(int count) => [
          for (var i = 0; i < count; i++)
            _finding(
              'x.err',
              Severity.error,
              'lib/f${i.toString().padLeft(2, '0')}.dart',
              line: 1,
            ),
        ];
        expect(
          await hook(
            checks: [
              _Reports(errors(35), ids: const ['x.err']),
            ],
          ),
          2,
        );
        final text = err.toString();
        expect(text, contains('lib/f29.dart'));
        expect(text, isNot(contains('lib/f30.dart')));
        expect(text, endsWith('…and 5 more: call the `verify` tool for all\n'));

        err.clear();
        expect(
          await hook(
            checks: [
              _Reports(errors(30), ids: const ['x.err']),
            ],
          ),
          2,
        );
        expect(err.toString(), contains('lib/f29.dart'));
        expect(err.toString(), isNot(contains('more: call the')));
      });

      test('an analyzer error of the code checks is one of them, with the '
          'real checks', () async {
        expect(
          await hook(
            analysis: ScriptedCodeAnalysis(
              found: const [
                CodeDiagnostic(
                  file: 'lib/ui/home screen.dart',
                  line: 12,
                  code: 'undefined_method',
                  message: "The method 'go' isn't defined for the type 'Home'.",
                  level: DiagnosticLevel.error,
                  correction: "Try correcting the name.",
                ),
              ],
            ),
          ),
          2,
        );
        expect(
          err.toString(),
          'lib/ui/home screen.dart\n'
          "  error dart.error (line 12): The method 'go' isn't defined for "
          "the type 'Home'. (`undefined_method`)\n"
          '    fix: Try correcting the name.\n',
        );
        expect(out.toString(), isEmpty);
      });

      test('checks named as not run are told on stderr too: it is the '
          'channel documented to reach the agent at exit 2', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [_finding('x.err', Severity.error, 'lib/a.dart', line: 1)],
                ids: const ['x.err'],
              ),
              _NotRunCheck('y.slow', 'the analysis server is starting'),
            ],
          ),
          2,
        );
        expect(err.toString(), contains('lib/a.dart\n  error x.err'));
        expect(
          err.toString(),
          contains('y.slow: the analysis server is starting'),
        );
        expect(out.toString(), isEmpty);
      });

      test('the input the hook was given changes nothing: missing, empty, '
          'broken or unreadable input still checks', () async {
        final findings = [
          _Reports(
            [_finding('x.err', Severity.error, 'lib/a.dart', line: 1)],
            ids: const ['x.err'],
          ),
        ];
        for (final input in ['', 'not json', '[]', '{"session_id": 3}']) {
          err.clear();
          expect(
            await hook(input: input, checks: findings),
            2,
            reason: input,
          );
          expect(err.toString(), contains('error x.err'), reason: input);
        }
        err.clear();
        expect(
          await hook(
            checks: findings,
            readInput: () async => throw const FileSystemException('closed'),
          ),
          2,
        );
        expect(err.toString(), contains('error x.err'));
      });
    });

    group('warnings and no error', () {
      test('exit 0; stdout is Claude Code\'s PostToolUse JSON with the '
          'warnings as context for the agent; stderr is empty', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  _finding(
                    'x.warn',
                    Severity.warning,
                    'lib/c.dart',
                    line: 4,
                    message: 'Unused.',
                    fix: 'Remove it.',
                    ref: '.appstein/map/x.json',
                  ),
                  _finding('x.info', Severity.info, 'lib/d.dart'),
                ],
                ids: ['x.warn', 'x.info'],
              ),
            ],
          ),
          0,
        );
        expect(err.toString(), isEmpty);
        expect(out.toString(), endsWith('\n'));
        // The shape Claude Code documents for a PostToolUse hook: the event
        // name and the context in `hookSpecificOutput`. No `systemMessage`:
        // the developer is not told about a warning after an edit.
        expect(stdoutJson(), {
          'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext':
                'Appstein checked the project after your change: no errors, '
                '1 warning.\n'
                '\n'
                'lib/c.dart\n'
                '  warning x.warn (line 4): Unused.\n'
                '    fix: Remove it.\n'
                '    knowledge: .appstein/map/x.json\n',
          },
        });
      });

      test('the context stays under 10,000 characters and says how many '
          'warnings it left out', () async {
        final long = 'w' * 700;
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  for (var i = 0; i < 60; i++)
                    _finding(
                      'x.warn',
                      Severity.warning,
                      'lib/f${i.toString().padLeft(2, '0')}.dart',
                      line: 1,
                      message: long,
                    ),
                ],
                ids: const ['x.warn'],
              ),
            ],
          ),
          0,
        );
        final text = context();
        expect(text.length, lessThan(10000));
        expect(text, contains('…and '));
        expect(text, endsWith(' more: call the `verify` tool for all\n'));
      });

      test('warnings are cut at 30 as errors are', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  for (var i = 0; i < 32; i++)
                    _finding(
                      'x.warn',
                      Severity.warning,
                      'lib/f${i.toString().padLeft(2, '0')}.dart',
                    ),
                ],
                ids: const ['x.warn'],
              ),
            ],
          ),
          0,
        );
        expect(context(), contains('lib/f29.dart'));
        expect(context(), isNot(contains('lib/f30.dart')));
        expect(
          context(),
          endsWith('…and 2 more: call the `verify` tool for all\n'),
        );
      });
    });

    group('nothing to say', () {
      test(
        'only info findings, or nothing: exit 0 and no output at all',
        () async {
          expect(
            await hook(
              checks: [
                _Reports(
                  [_finding('x.info', Severity.info, 'lib/d.dart')],
                  ids: const ['x.info'],
                ),
              ],
            ),
            0,
          );
          expect(out.toString(), isEmpty);
          expect(err.toString(), isEmpty);

          expect(await hook(), 0);
          expect(out.toString(), isEmpty);
          expect(err.toString(), isEmpty);
        },
      );
    });

    group('checks that did not run', () {
      test('are said in the context, so silence never hides an unchecked '
          'edit, whether or not there are warnings', () async {
        // The knowledge cannot be refreshed: a check that needs the map is
        // named as not run, and `knowledge.stale` is an error. Here the
        // packages are fresh but the check says itself that it did not run.
        final notRunning = _NotRunCheck(
          'x.slow',
          'the analysis server is starting',
        );
        expect(await hook(checks: [notRunning]), 0);
        expect(err.toString(), isEmpty);
        expect(stdoutJson().keys, ['hookSpecificOutput']);
        expect(
          context(),
          allOf(
            contains('x.slow: the analysis server is starting'),
            contains('not checked'),
          ),
        );

        out.clear();
        expect(
          await hook(
            checks: [
              notRunning,
              _Reports(
                [_finding('x.warn', Severity.warning, 'lib/c.dart', line: 2)],
                ids: const ['x.warn'],
              ),
            ],
          ),
          0,
        );
        expect(context(), contains('warning x.warn (line 2)'));
        expect(context(), contains('x.slow: the analysis server is starting'));
      });
    });

    group('nothing changed means no output', () {
      String sessionInput(String id) =>
          '{"session_id":"$id","hook_event_name":"PostToolUse"}';

      File fileOf(String relative) =>
          File(p.joinAll([project, ...relative.split('/')]));

      void write(String relative, String text) => fileOf(relative)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);

      /// Edits `pubspec.yaml` but keeps the packages fresh, as if `flutter pub
      /// get` had run after it.
      void editPubspec() {
        final pubspec = fileOf('pubspec.yaml');
        pubspec.writeAsStringSync('${pubspec.readAsStringSync()}# edited\n');
        pubspec.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );
      }

      /// What another session's `appstein mcp` does before each tool call: it
      /// refreshes the shared knowledge (`sync --detect`).
      Future<SyncReport> refreshAsAnotherSession() {
        const config = AppsteinConfig();
        return KnowledgeSync(
          environment: HostEnvironment(
            os: HostOs.current,
            variables: {'FLUTTER_ROOT': sdk},
            workingDirectory: project,
          ),
          appsteinVersion: appsteinVersion,
          packs: packsFor(config),
          baseline: config.delta.baseline,
          agents: config.integrations.agents,
          packageSkills: false,
        ).detect(project, dartSdkPath: testDartSdk);
      }

      KnowledgeState state() => KnowledgeState.fromJson(
        jsonDecode(fileOf('.appstein/state.json').readAsStringSync())
            as Map<String, Object?>,
      );

      Directory records() => Directory(p.join(project, '.appstein'));

      test(
        'a session\'s first run checks; the next, with nothing changed '
        '(`ls`, `git status`), exits 0 with no output and runs no check',
        () async {
          final check = _Counting();
          expect(await hook(input: sessionInput('a'), checks: [check]), 0);
          expect(check.runs, 1);

          for (var i = 0; i < 3; i++) {
            out.clear();
            err.clear();
            expect(await hook(input: sessionInput('a'), checks: [check]), 0);
            expect(out.toString(), isEmpty);
            expect(err.toString(), isEmpty);
          }
          expect(check.runs, 1, reason: 'a silent run runs no check');
        },
      );

      test('a silent run asks the analysis for nothing and writes no file '
          'of the knowledge', () async {
        final analysis = ScriptedCodeAnalysis();
        await hook(input: sessionInput('a'), analysis: analysis);
        final asked = analysis.asked;
        final stateBefore = fileOf('.appstein/state.json').readAsStringSync();
        final files = {
          for (final f in records().listSync(recursive: true).whereType<File>())
            f.path: f.lastModifiedSync(),
        };
        expect(await hook(input: sessionInput('a'), analysis: analysis), 0);
        expect(analysis.asked, asked);
        expect(fileOf('.appstein/state.json').readAsStringSync(), stateBefore);
        expect({
          for (final f in records().listSync(recursive: true).whereType<File>())
            f.path: f.lastModifiedSync(),
        }, files);
      });

      test('another session\'s first run checks, though this one already '
          'did: the comparison is per session', () async {
        final check = _Counting();
        await hook(input: sessionInput('a'), checks: [check]);
        await hook(input: sessionInput('b'), checks: [check]);
        expect(check.runs, 2);
        // Now both are silent.
        await hook(input: sessionInput('a'), checks: [check]);
        await hook(input: sessionInput('b'), checks: [check]);
        expect(check.runs, 2);
      });

      test(
        'a run with no session always checks, and keeps no record',
        () async {
          final check = _Counting();
          var runs = 0;
          for (final input in ['', 'not json', '{}', '{"session_id": 5}']) {
            for (var i = 0; i < 2; i++) {
              expect(await hook(input: input, checks: [check]), 0);
              runs += 1;
              expect(check.runs, runs, reason: 'input "$input", run $i');
            }
          }
          expect(
            Directory(
              p.join(project, '.appstein', 'hook-sessions'),
            ).existsSync(),
            isFalse,
          );
        },
      );

      /// Edits the project with [edit] and runs session `a`'s hook: it checks
      /// when [checked], else it is silent. Run again it is quiet either way.
      Future<void> expectAfter(
        _Counting check,
        String what,
        void Function() edit, {
        required bool checked,
      }) async {
        final before = check.runs;
        edit();
        out.clear();
        err.clear();
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, before + (checked ? 1 : 0), reason: what);
        // The check ran once for the edit; run again and it is quiet.
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, before + (checked ? 1 : 0), reason: '$what, again');
      }

      test('an edit to a file Appstein does not read gives no output; an edit '
          'to a Dart file, pubspec.yaml or another file the knowledge reads '
          'gives a check', () async {
        final check = _Counting();
        await hook(input: sessionInput('a'), checks: [check]);
        expect(check.runs, 1);

        await expectAfter(
          check,
          'README.md',
          () => write('README.md', '# My app\n'),
          checked: false,
        );
        await expectAfter(
          check,
          'an asset',
          () => write('assets/logo.txt', 'logo'),
          checked: false,
        );
        await expectAfter(
          check,
          'lib/main.dart',
          () => write('lib/main.dart', 'void main() { print(1); }\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'a new Dart file in lib/',
          () => write('lib/extra.dart', '/// E.\nclass E {}\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'a Dart file outside the map\'s folders',
          () => write('bin/tool.dart', 'void main() {}\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'a test',
          () => write('test/main_test.dart', 'void main() {}\n'),
          checked: true,
        );
        await expectAfter(check, 'pubspec.yaml', editPubspec, checked: true);
        await expectAfter(
          check,
          'analysis_options.yaml',
          () => write('analysis_options.yaml', 'linter:\n  rules: []\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'a Dart file deleted',
          () => fileOf('bin/tool.dart').deleteSync(),
          checked: true,
        );
        await expectAfter(
          check,
          'a decision record',
          () => write(
            '.appstein/decisions/0001-state.md',
            '# State\n\nStatus: accepted\n',
          ),
          checked: true,
        );
      });

      test('an edit to a file only the checks read gives a check: '
          'appstein.yaml (a suppression removed, a severity raised), an '
          'analysis_options.yaml below the root or above the project, a file an options file '
          'includes, pubspec.lock and the package configuration', () async {
        final check = _Counting();
        await hook(input: sessionInput('a'), checks: [check]);
        expect(check.runs, 1);

        await expectAfter(
          check,
          'a suppression added',
          () => write(
            'appstein.yaml',
            'appstein: 1\n'
                'suppressions:\n'
                '  - id: x.count\n'
                '    path: lib/main.dart\n'
                '    reason: Known.\n',
          ),
          checked: true,
        );
        await expectAfter(
          check,
          'the suppression removed',
          () => write('appstein.yaml', 'appstein: 1\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'a severity raised',
          () => write(
            'appstein.yaml',
            'appstein: 1\nverify:\n  severity:\n    x.count: error\n',
          ),
          checked: true,
        );
        await expectAfter(
          check,
          'a nested analysis_options.yaml',
          () => write('lib/ui/analysis_options.yaml', 'linter:\n  rules: []\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'the nested analysis_options.yaml edited',
          () => write(
            'lib/ui/analysis_options.yaml',
            'linter:\n  rules: [unused_import]\n',
          ),
          checked: true,
        );
        // The analyzer applies the file above the project to a project with
        // no options file of its own, which this one has not yet.
        final above = File(p.join(work.path, 'analysis_options.yaml'));
        await expectAfter(
          check,
          'an analysis_options.yaml in the folder above the project',
          () => above.writeAsStringSync('linter:\n  rules: []\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'the one above the project edited',
          () => above.writeAsStringSync('linter:\n  rules: [unused_import]\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'the one above the project gone',
          above.deleteSync,
          checked: true,
        );
        await expectAfter(check, 'a file the root options include', () {
          write('shared/base.yaml', 'linter:\n  rules: []\n');
          write('analysis_options.yaml', 'include: shared/base.yaml\n');
        }, checked: true);
        await expectAfter(
          check,
          'the included file edited',
          () =>
              write('shared/base.yaml', 'linter:\n  rules: [unused_import]\n'),
          checked: true,
        );
        await expectAfter(
          check,
          'pubspec.lock',
          () => write('pubspec.lock', 'packages: {}\n# edited\n'),
          checked: true,
        );
        await expectAfter(check, 'the package configuration', () {
          final config = fileOf('.dart_tool/package_config.json');
          write(
            '.dart_tool/package_config.json',
            '${config.readAsStringSync()}\n',
          );
        }, checked: true);
      });

      test('files that change while the checks run, and change back, are '
          'not taken for checked: nothing is saved, so the next run '
          'checks', () async {
        final original = fileOf('lib/main.dart').readAsStringSync();
        final check = _EditsWhileRunning(
          fileOf('lib/main.dart'),
          'void main() { print("changed during the check"); }\n',
        );
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, 1);
        expect(
          Directory(p.join(project, '.appstein', 'hook-sessions')).existsSync(),
          isFalse,
          reason: 'no record was saved',
        );

        // The agent undoes the change: the project is as it was when the run
        // began, and was never checked as it is now.
        write('lib/main.dart', original);
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, 2, reason: 'not silent');

        // That run changed nothing meanwhile, so now it is quiet.
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, 2);
      });

      test('it is judged against this session\'s own last run, not against '
          'the shared state: session A edits a file, session B\'s refresh '
          'uses up the change, then A\'s hook still checks and reports A\'s '
          'error', () async {
        final check = _FindsBroken();
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(await hook(input: sessionInput('b'), checks: [check]), 0);
        expect(check.runs, 2);

        // Session A edits a file and breaks it.
        write('lib/main.dart', 'void main() { BROKEN }\n');

        // Session B's `appstein mcp` refreshes the knowledge before a tool
        // call. It sees the change, so for the shared state nothing is new
        // any more.
        final refresh = await refreshAsAnotherSession();
        expect(refresh.current, isFalse, reason: 'B saw the edit');
        expect(state().unverified, contains('lib/main.dart'));
        // B's next call finds nothing changed against the state, and uses
        // up the change list.
        expect(
          (await refreshAsAnotherSession()).current,
          isTrue,
          reason: 'a second refresh finds nothing changed against the state',
        );
        expect(state().changed, isEmpty);

        // A's hook still checks, and reports A's error.
        out.clear();
        err.clear();
        expect(await hook(input: sessionInput('a'), checks: [check]), 2);
        expect(check.runs, 3);
        expect(err.toString(), contains('lib/main.dart'));
        expect(err.toString(), contains('BROKEN'));

        // B's hook also checks: B has not run since the edit either.
        expect(await hook(input: sessionInput('b'), checks: [check]), 2);
        expect(check.runs, 4);
      });

      test('errors already reported stay in the unverified files, and a '
          'silent run never lets a file leave them', () async {
        const error = CodeDiagnostic(
          file: 'lib/main.dart',
          line: 1,
          code: 'undefined_method',
          message: 'Broken.',
          level: DiagnosticLevel.error,
        );
        final analysis = ScriptedCodeAnalysis(
          found: const [error],
          analyzedFiles: const ['lib/main.dart'],
        );
        expect(
          await hook(input: sessionInput('a'), analysis: analysis),
          2,
          reason: '$err',
        );
        expect(err.toString(), contains('lib/main.dart'));
        expect(state().unverified, contains('lib/main.dart'));
        final stateBefore = fileOf('.appstein/state.json').readAsStringSync();

        // Nothing changed: silent, though the error is still there. It stays
        // for the Stop hook.
        out.clear();
        err.clear();
        expect(await hook(input: sessionInput('a'), analysis: analysis), 0);
        expect(out.toString(), isEmpty);
        expect(err.toString(), isEmpty);
        expect(state().unverified, contains('lib/main.dart'));
        expect(fileOf('.appstein/state.json').readAsStringSync(), stateBefore);

        // The agent fixes the file: a check, which lets it leave.
        write('lib/main.dart', 'void main() { print(2); }\n');
        analysis.found = const [];
        expect(await hook(input: sessionInput('a'), analysis: analysis), 0);
        expect(state().unverified, isNot(contains('lib/main.dart')));
      });

      test(
        'a run that failed is no run completed: the next run checks',
        () async {
          final check = _Counting();
          // Appstein fails: the edit is unchecked.
          expect(
            await hook(
              input: sessionInput('a'),
              analysis: ScriptedCodeAnalysis(
                failure: const CodeAnalysisException('it did not answer'),
              ),
            ),
            0,
          );
          expect(out.toString(), contains('unchecked'));

          out.clear();
          err.clear();
          expect(await hook(input: sessionInput('a'), checks: [check]), 0);
          expect(check.runs, 1, reason: 'not silent after a failed run');

          // A check that throws is the same.
          expect(
            await hook(input: sessionInput('c'), checks: const [_Throws()]),
            0,
          );
          out.clear();
          expect(await hook(input: sessionInput('c'), checks: [check]), 0);
          expect(check.runs, 2);
        },
      );

      test('a run that names checks as not run is no run completed: the '
          'next run checks again and says them again', () async {
        final notRunning = _NotRunCheck(
          'x.slow',
          'the analysis server is starting',
        );
        for (var i = 0; i < 3; i++) {
          out.clear();
          err.clear();
          expect(await hook(input: sessionInput('a'), checks: [notRunning]), 0);
          expect(
            context(),
            contains('x.slow: the analysis server is starting'),
            reason: 'run $i',
          );
        }
      });

      test('a run with errors is a completed run: the next, with nothing '
          'changed, is silent', () async {
        final check = _Reports(
          [_finding('x.err', Severity.error, 'lib/a.dart')],
          ids: const ['x.err'],
        );
        expect(await hook(input: sessionInput('a'), checks: [check]), 2);
        out.clear();
        err.clear();
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(out.toString(), isEmpty);
        expect(err.toString(), isEmpty);
      });

      test('--files asks for a check: it is never silent', () async {
        final check = _Counting();
        await hook(input: sessionInput('a'), checks: [check]);
        expect(
          await hook(
            input: sessionInput('a'),
            checks: [check],
            extra: ['--files', 'lib/main.dart'],
          ),
          0,
        );
        expect(check.runs, 2);
      });

      test('a record that is damaged is no record: the run checks', () async {
        final check = _Counting();
        await hook(input: sessionInput('a'), checks: [check]);
        final folder = Directory(
          p.join(project, '.appstein', 'hook-sessions', 'records'),
        );
        final record = folder.listSync().whereType<File>().single;
        record.writeAsStringSync('{ not json');
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, 2);
        // And it is whole again.
        expect(await hook(input: sessionInput('a'), checks: [check]), 0);
        expect(check.runs, 2);
      });
    });

    group('the Stop hook (--full)', () {
      /// The input Claude Code gives a Stop hook.
      String stopInput(String? id, {bool? active, String event = 'Stop'}) =>
          jsonEncode({
            'session_id': ?id,
            'hook_event_name': event,
            'stop_hook_active': ?active,
          });

      /// A check that reports the error [message] at [line] of [file].
      VerifyCheck brokenFile({
        int line = 1,
        String message = 'Broken.',
        String file = 'lib/a.dart',
      }) => _Reports(
        [_finding('x.err', Severity.error, file, line: line, message: message)],
        ids: const ['x.err'],
      );

      /// The input Claude Code gives the PostToolUse hook of a session.
      String postInput(String id) =>
          jsonEncode({'session_id': id, 'hook_event_name': 'PostToolUse'});

      var nextStopSession = 0;

      /// Runs the Stop hook for [input], with [extra] flags. Without an input
      /// every call is a new session's Stop.
      Future<int> stop({
        String? input,
        List<VerifyCheck>? checks,
        List<String> extra = const [],
        ScriptedCodeAnalysis? analysis,
        CodeAnalysisScope? scope,
      }) {
        out.clear();
        err.clear();
        return hook(
          arguments: ['verify', '--full', '--hook', 'claude', ...extra],
          input: input ?? stopInput('new-stop-${++nextStopSession}'),
          checks: checks,
          analysis: analysis,
          scope: scope,
        );
      }

      Map<String, Object?> stopJson() => stdoutJson();

      group('answers', () {
        test('errors: exit 2 and stderr exactly as after an edit, with the '
            'checks that did not run; stdout is empty', () async {
          expect(
            await stop(
              checks: [
                _Reports(
                  [
                    _finding(
                      'x.one',
                      Severity.error,
                      'lib/b.dart',
                      line: 3,
                      message: 'Broken b.',
                      fix: 'Fix b.',
                      ref: '.appstein/map/routes.json#home',
                    ),
                    _finding(
                      'x.three',
                      Severity.warning,
                      'lib/c.dart',
                      message: 'Only a warning.',
                    ),
                  ],
                  ids: ['x.one', 'x.three'],
                ),
                _NotRunCheck('y.slow', 'the analysis server is starting'),
              ],
            ),
            2,
          );
          expect(out.toString(), isEmpty);
          expect(
            err.toString(),
            startsWith(
              'lib/b.dart\n'
              '  error x.one (line 3): Broken b.\n'
              '    fix: Fix b.\n'
              '    knowledge: .appstein/map/routes.json#home\n',
            ),
          );
          expect(
            err.toString(),
            contains('y.slow: the analysis server is starting'),
          );
          expect(err.toString(), isNot(contains('only a warning')));
        });

        test('more than 30 errors are cut as after an edit', () async {
          expect(
            await stop(
              checks: [
                _Reports(
                  [
                    for (var i = 0; i < 35; i++)
                      _finding(
                        'x.err',
                        Severity.error,
                        'lib/f${i.toString().padLeft(2, '0')}.dart',
                      ),
                  ],
                  ids: const ['x.err'],
                ),
              ],
            ),
            2,
          );
          expect(
            err.toString(),
            endsWith('…and 5 more: call the `verify` tool for all\n'),
          );
        });

        test('an analyzer error of the real code checks blocks too', () async {
          expect(
            await stop(
              analysis: ScriptedCodeAnalysis(
                found: const [
                  CodeDiagnostic(
                    file: 'lib/main.dart',
                    line: 2,
                    code: 'undefined_method',
                    message: 'No such method.',
                    level: DiagnosticLevel.error,
                  ),
                ],
              ),
            ),
            2,
          );
          expect(err.toString(), contains('error dart.error (line 2)'));
        });

        test(
          'warnings and no error: exit 0 and a JSON message for the '
          'developer, never context for the agent; stderr is empty',
          () async {
            expect(
              await stop(
                checks: [
                  _Reports(
                    [
                      _finding(
                        'x.warn',
                        Severity.warning,
                        'lib/c.dart',
                        line: 4,
                        message: 'Unused.',
                        fix: 'Remove it.',
                      ),
                      _finding('x.info', Severity.info, 'lib/d.dart'),
                    ],
                    ids: ['x.warn', 'x.info'],
                  ),
                ],
              ),
              0,
            );
            expect(err.toString(), isEmpty);
            expect(out.toString(), endsWith('\n'));
            expect(stopJson(), {
              'systemMessage':
                  'Appstein checked the project: no errors, 1 warning.\n'
                  '\n'
                  'lib/c.dart\n'
                  '  warning x.warn (line 4): Unused.\n'
                  '    fix: Remove it.\n',
            });
          },
        );

        test('warnings are cut at 30, and the message stays under 10,000 '
            'characters', () async {
          expect(
            await stop(
              checks: [
                _Reports(
                  [
                    for (var i = 0; i < 40; i++)
                      _finding(
                        'x.warn',
                        Severity.warning,
                        'lib/f${i.toString().padLeft(2, '0')}.dart',
                        message: 'w' * 700,
                      ),
                  ],
                  ids: const ['x.warn'],
                ),
              ],
            ),
            0,
          );
          final message = stopJson()['systemMessage']! as String;
          expect(message.length, lessThan(10000));
          expect(message, contains(' more: call the `verify` tool for all'));
          expect(stopJson().keys, ['systemMessage']);
        });

        test(
          'only info findings, or nothing: exit 0 and no output at all',
          () async {
            expect(
              await stop(
                checks: [
                  _Reports(
                    [_finding('x.info', Severity.info, 'lib/d.dart')],
                    ids: const ['x.info'],
                  ),
                ],
              ),
              0,
            );
            expect(out.toString(), isEmpty);
            expect(err.toString(), isEmpty);

            expect(await stop(), 0);
            expect(out.toString(), isEmpty);
            expect(err.toString(), isEmpty);
          },
        );

        test('checks that did not run are told to the developer, since '
            'silence never hides an unchecked project', () async {
          expect(
            await stop(
              checks: [_NotRunCheck('x.slow', 'the analysis server is gone')],
            ),
            0,
          );
          expect(stopJson().keys, ['systemMessage']);
          expect(
            stopJson()['systemMessage'],
            contains('x.slow: the analysis server is gone'),
          );
          expect(err.toString(), isEmpty);
        });

        test('notices are the whole message when there is nothing else, '
            'and beside the warnings', () async {
          const notice = 'Process 7 may be an analysis server.';
          expect(
            await stop(analysis: ScriptedCodeAnalysis(notices: const [notice])),
            0,
          );
          expect(stopJson(), {'systemMessage': 'Appstein note: $notice'});

          expect(
            await stop(
              extra: ['--apply'],
              analysis: ScriptedCodeAnalysis(
                notices: const [notice],
                found: const [
                  CodeDiagnostic(
                    file: 'lib/main.dart',
                    line: 2,
                    code: 'unused_import',
                    message: 'Unused import.',
                    level: DiagnosticLevel.warning,
                  ),
                ],
              ),
            ),
            0,
          );
          expect(stopJson().keys, ['systemMessage']);
          final message = stopJson()['systemMessage']! as String;
          expect(message, contains('warning dart.warning (line 2)'));
          expect(message, endsWith('Appstein note: $notice'));
        });

        test('notices beside the errors of exit 2 are the developer\'s '
            'systemMessage, as after an edit', () async {
          const notice = 'Process 7 may be an analysis server.';
          expect(
            await stop(
              analysis: ScriptedCodeAnalysis(
                notices: const [notice],
                found: const [
                  CodeDiagnostic(
                    file: 'lib/main.dart',
                    line: 1,
                    code: 'undefined_method',
                    message: 'No such method.',
                    level: DiagnosticLevel.error,
                  ),
                ],
              ),
            ),
            2,
          );
          expect(stopJson(), {'systemMessage': 'Appstein note: $notice'});
          expect(err.toString(), contains('error dart.error (line 1)'));
        });

        test('Appstein failing: exit 0 and the developer\'s message only, '
            'with the details on stderr; the agent gets no context', () async {
          expect(
            await stop(
              analysis: ScriptedCodeAnalysis(
                failure: const CodeAnalysisException('it did not answer'),
              ),
            ),
            0,
          );
          expect(stopJson().keys, ['systemMessage']);
          final message = stopJson()['systemMessage']! as String;
          expect(message, contains('it did not answer'));
          expect(message, contains('run `appstein doctor`'));
          expect(
            err.toString(),
            contains('The Dart analysis server could not answer'),
          );

          expect(await stop(checks: const [_Throws()]), 0);
          expect(stopJson().keys, ['systemMessage']);
          expect(stopJson()['systemMessage'], contains('boom.check'));

          expect(
            await stop(scope: <T>(body) => throw StateError('it fell')),
            0,
          );
          expect(stopJson().keys, ['systemMessage']);
          expect(err.toString(), contains('#0'));
          expect(out.toString(), isNot(contains('#0')));
        });

        test('a failure before the command runs is the same at Stop, with '
            '--full, with --hook=claude and with neither flag; a fast run '
            'still tells the agent', () async {
          for (final flags in [
            ['--full', '--hook', 'claude'],
            ['--hook=claude'],
            ['--apply', '--hook', 'claude'],
          ]) {
            out.clear();
            err.clear();
            expect(
              await runAppstein(
                ['verify', ...flags],
                out: out,
                err: err,
                environmentFactory: () =>
                    throw const FileSystemException('cwd gone'),
              ),
              0,
              reason: '$flags',
            );
            expect(stopJson().keys, ['systemMessage'], reason: '$flags');
            expect(stopJson()['systemMessage'], contains('cwd gone'));
          }
          out.clear();
          await runAppstein(
            ['verify', '--fast', '--hook', 'claude'],
            out: out,
            err: err,
            environmentFactory: () =>
                throw const FileSystemException('cwd gone'),
          );
          expect(stopJson().keys.toSet(), {
            'hookSpecificOutput',
            'systemMessage',
          });
        });

        final warning = _Reports(
          [_finding('x.warn', Severity.warning, 'lib/c.dart')],
          ids: const ['x.warn'],
        );

        test('with neither --fast nor --full a hook run answers as Stop, '
            'start to end: warnings go to the developer only, errors block, '
            'and the loop guard counts', () async {
          Future<int> bare(String input, List<VerifyCheck> checks) {
            out.clear();
            err.clear();
            return hook(
              arguments: ['verify', '--hook', 'claude'],
              input: input,
              checks: checks,
            );
          }

          expect(await bare(stopInput('a'), [warning]), 0);
          expect(stopJson().keys, ['systemMessage']);
          expect(err.toString(), isEmpty);

          for (var i = 0; i < 3; i++) {
            expect(
              await bare(stopInput('b', active: i > 0), [brokenFile()]),
              2,
              reason: 'run $i',
            );
            expect(err.toString(), contains('error x.err'));
          }
          expect(await bare(stopInput('b', active: true), [brokenFile()]), 0);
          expect(stopJson()['systemMessage'], contains('3 times in a row'));

          // And the same with no input at all: the flags decide.
          expect(await bare('', [warning]), 0);
          expect(stopJson().keys, ['systemMessage']);
        });

        test('the event the input names decides the kind of run: a Stop '
            'event is the Stop hook even for --fast, and any other event '
            'is the after-edit hook even for a full run', () async {
          // A fast run whose input says Stop.
          expect(await hook(input: stopInput('a'), checks: [warning]), 0);
          expect(stopJson().keys, ['systemMessage']);

          // A full run whose input says PostToolUse.
          expect(await stop(input: postInput('b'), checks: [warning]), 0);
          expect(stopJson().keys, ['hookSpecificOutput']);
        });

        test('a full run whose input names another event than Stop reads '
            'and saves no loop guard: it is blocked as after an edit and '
            'leaves the count of the Stop hook alone', () async {
          // Two Stop blocks.
          await stop(
            input: stopInput('s', active: false),
            checks: [brokenFile()],
          );
          await stop(
            input: stopInput('s', active: true),
            checks: [brokenFile()],
          );
          final record = Directory(
            HookSessions(project).folder,
          ).listSync().whereType<File>().single;
          final before = record.readAsStringSync();

          // A PostToolUse hook set up without --fast: any number of runs
          // block as after an edit, even with stop_hook_active true, and
          // the record's guard stays as the Stop hook left it.
          for (var i = 0; i < 5; i++) {
            expect(
              await stop(
                input: jsonEncode({
                  'session_id': 's',
                  'hook_event_name': 'PostToolUse',
                  'stop_hook_active': true,
                }),
                checks: [brokenFile()],
              ),
              2,
              reason: 'run $i',
            );
            expect(err.toString(), contains('error x.err'));
          }
          expect(
            HookSessions(project).readGuard('s')!.count,
            2,
            reason: 'the guard is the Stop hook\'s',
          );
          expect(record.readAsStringSync().contains('"guard"'), isTrue);
          expect(before.contains('"guard"'), isTrue);

          // A session whose only runs are such: no guard is ever written.
          await stop(
            input: jsonEncode({
              'session_id': 'only-post',
              'hook_event_name': 'PostToolUse',
            }),
            checks: [brokenFile()],
          );
          expect(HookSessions(project).readGuard('only-post'), isNull);

          // The next Stop goes on counting from 2: block, then let go.
          expect(
            await stop(
              input: stopInput('s', active: true),
              checks: [brokenFile()],
            ),
            2,
          );
          expect(
            await stop(
              input: stopInput('s', active: true),
              checks: [brokenFile()],
            ),
            0,
          );
        });

        test('missing input still checks and blocks', () async {
          for (final input in ['', 'not json', '[]']) {
            expect(
              await stop(input: input, checks: [brokenFile()]),
              2,
              reason: input,
            );
            expect(err.toString(), contains('error x.err'));
          }
        });
      });

      group('--apply', () {
        test('fixes and formats, renders the human docs, then runs every '
            'check: in that order, in hook mode as without it', () async {
          final docs = Directory(p.join(project, 'docs', 'app'));
          expect(docs.existsSync(), isTrue, reason: 'a healthy project');
          docs.deleteSync(recursive: true);
          final order = <String>[];
          final analysis = ScriptedCodeAnalysis()
            ..onApply = (_) async {
              order.add('apply');
              return ['lib/fixed.dart'];
            };
          expect(
            await stop(
              extra: ['--apply'],
              analysis: analysis,
              checks: [_NotifyingCheck(() => order.add('check'))],
            ),
            0,
            reason: '$err',
          );
          expect(order, ['apply', 'check']);
          expect(analysis.applyAsked, 1);
          // The pages are back, and nothing else was said.
          expect(docs.existsSync(), isTrue);
          expect(docs.listSync(recursive: true).whereType<File>(), isNotEmpty);
          expect(out.toString(), isEmpty);
          expect(err.toString(), isEmpty);
        });

        test('errors after the rewrite still block with exit 2, and stderr '
            'names the files it rewrote, first, to be read again before '
            'they are edited', () async {
          final analysis = ScriptedCodeAnalysis()..applied = ['lib/a.dart'];
          expect(
            await stop(
              extra: ['--apply'],
              analysis: analysis,
              checks: [brokenFile()],
            ),
            2,
          );
          expect(analysis.applyAsked, 1);
          expect(
            err.toString(),
            startsWith(
              'Rewritten by --apply (read this file again before you edit '
              'it):\n'
              '  lib/a.dart\n'
              '\n'
              'lib/a.dart\n'
              '  error x.err (line 1): Broken.\n',
            ),
          );
          expect(out.toString(), isEmpty);

          analysis.applied = ['lib/a.dart', 'lib/b c.dart'];
          expect(
            await stop(
              extra: ['--apply'],
              analysis: analysis,
              checks: [brokenFile()],
            ),
            2,
          );
          expect(
            err.toString(),
            startsWith(
              'Rewritten by --apply (read these files again before you edit '
              'them):\n'
              '  lib/a.dart\n'
              '  lib/b c.dart\n'
              '\n'
              'lib/a.dart\n',
            ),
          );
        });

        test('the files rewritten are listed to 30, and the whole stderr '
            'stays under 10,000 characters', () async {
          final analysis = ScriptedCodeAnalysis()
            ..applied = [
              for (var i = 0; i < 40; i++) 'lib/${'f' * 600}$i.dart',
            ];
          expect(
            await stop(
              extra: ['--apply'],
              analysis: analysis,
              checks: [brokenFile()],
            ),
            2,
          );
          final text = err.toString();
          expect(text, contains('…and '));
          expect(text.length, lessThan(10000));
          // The list ends on its own line, before the errors.
          expect(text, contains('\n\nlib/a.dart\n  error x.err (line 1)'));

          analysis.applied = [for (var i = 0; i < 40; i++) 'lib/f$i.dart'];
          expect(
            await stop(
              extra: ['--apply'],
              analysis: analysis,
              checks: [brokenFile()],
            ),
            2,
          );
          expect(err.toString(), contains('  lib/f29.dart\n  …and 10 more\n'));
          expect(err.toString(), isNot(contains('lib/f30.dart')));
        });

        test('a run that does not block says nothing of the files it '
            'rewrote: the agent is not continuing', () async {
          final analysis = ScriptedCodeAnalysis()..applied = ['lib/a.dart'];
          expect(await stop(extra: ['--apply'], analysis: analysis), 0);
          expect(out.toString(), isEmpty);
          expect(err.toString(), isEmpty);
        });

        test('without it nothing is asked to rewrite', () async {
          final analysis = ScriptedCodeAnalysis();
          await stop(analysis: analysis);
          expect(analysis.applyAsked, 0);
        });
      });

      group('the Stop hook and "nothing changed" share a record and '
          'break neither', () {
        test('a full run is never silent: nothing changed, and it checks '
            'every time', () async {
          final check = _Counting();
          for (var i = 0; i < 3; i++) {
            expect(await stop(input: stopInput('a'), checks: [check]), 0);
            expect(out.toString(), isEmpty);
          }
          expect(check.runs, 3);
        });

        test('a fast run\'s record does not silence a full run, and a full '
            'run does not silence the next fast run, whether or not the '
            'fast run had a record', () async {
          final check = _Counting();
          // A fast run saves its record.
          await hook(input: postInput('a'), checks: [check]);
          expect(check.runs, 1);
          // The full run checks though nothing changed.
          await stop(input: stopInput('a'), checks: [check]);
          expect(check.runs, 2);
          // The fast run is still silent: the Stop run left its record.
          await hook(input: postInput('a'), checks: [check]);
          expect(check.runs, 2);

          // A session whose first run is a full one: its first fast run
          // checks (a Stop run saved no fingerprint).
          await stop(input: stopInput('b'), checks: [check]);
          expect(check.runs, 3);
          await hook(input: postInput('b'), checks: [check]);
          expect(check.runs, 4);
          await hook(input: postInput('b'), checks: [check]);
          expect(check.runs, 4);
        });

        test('a Stop run that rewrites files does not make the next fast '
            'run silent over them: the fast run sees the rewritten files '
            'changed', () async {
          final check = _Counting();
          await hook(input: postInput('a'), checks: [check]);
          expect(check.runs, 1);
          final analysis = ScriptedCodeAnalysis()
            ..onApply = (_) async {
              File(
                p.join(project, 'lib', 'main.dart'),
              ).writeAsStringSync('void main() { print("fixed"); }\n');
              return ['lib/main.dart'];
            };
          await stop(
            input: stopInput('a'),
            extra: ['--apply'],
            analysis: analysis,
            checks: [check],
          );
          expect(check.runs, 2);
          await hook(input: postInput('a'), checks: [check]);
          expect(check.runs, 3, reason: 'the rewritten file is a change');
        });
      });

      group('the loop guard', () {
        /// One Stop run of session [id], with [checks] (the same error by
        /// default). [active] is the input's stop_hook_active.
        Future<int> call(
          String id, {
          bool active = true,
          List<VerifyCheck>? checks,
        }) => stop(
          input: stopInput(id, active: active),
          checks: checks ?? [brokenFile()],
        );

        /// [count] Stop runs of session [id] in a row, the first not
        /// continuing and the rest continuing, as Claude Code gives them.
        Future<List<int>> runs(
          String id,
          int count, {
          List<VerifyCheck>? checks,
        }) async => [
          for (var i = 0; i < count; i++)
            await call(id, active: i > 0, checks: checks),
        ];

        test('the same errors block three times in a row and the fourth '
            'Stop lets the agent go, with the errors that remain told to '
            'the developer', () async {
          expect(await runs('loop', 3), [2, 2, 2]);
          expect(err.toString(), contains('error x.err'));

          // The fourth.
          expect(await call('loop'), 0);
          expect(err.toString(), isEmpty);
          expect(stopJson().keys, ['systemMessage']);
          expect(
            stopJson()['systemMessage'],
            startsWith(
              'Appstein let the agent stop with 1 error left: the same error '
              'has blocked it 3 times in a row in this session. The '
              'remaining error:\n'
              '\n'
              'lib/a.dart\n'
              '  error x.err (line 1): Broken.\n',
            ),
          );
          // A fifth and a sixth with the same errors go on letting it go.
          expect(await call('loop'), 0);
          expect(await call('loop'), 0);
        });

        test('the message lists every remaining error, cut at 30', () async {
          final many = _Reports(
            [
              for (var i = 0; i < 32; i++)
                _finding(
                  'x.err',
                  Severity.error,
                  'lib/f${i.toString().padLeft(2, '0')}.dart',
                  line: 1,
                ),
            ],
            ids: const ['x.err'],
          );
          expect(await runs('s', 3, checks: [many]), [2, 2, 2]);
          expect(await call('s', checks: [many]), 0);
          final message = stopJson()['systemMessage']! as String;
          expect(message, contains('with 32 errors left'));
          expect(message, contains('lib/f29.dart'));
          expect(message, isNot(contains('lib/f30.dart')));
          expect(message, contains('…and 2 more: call the `verify` tool'));
          expect(message.length, lessThan(10000));
        });

        test('the count starts again when the agent is not continuing: '
            'every Stop with stop_hook_active false or missing is a first '
            'block', () async {
          for (final input in [stopInput('s', active: false), stopInput('s')]) {
            for (var i = 0; i < 5; i++) {
              expect(await stop(input: input, checks: [brokenFile()]), 2);
            }
          }
          // And after such a reset the count goes on from 1.
          expect(
            [await call('s'), await call('s'), await call('s')],
            [2, 2, 0],
          );
        });

        test('a Stop that is not continuing in the middle of a count '
            'starts it again', () async {
          expect(await runs('s', 3), [2, 2, 2]);
          // A new task: the agent says done again, not continuing.
          expect(await runs('s', 3), [2, 2, 2]);
          expect(await call('s'), 0);
        });

        test('the count starts again when the set of errors changes: a new '
            'message, a new file, an added error', () async {
          VerifyCheck two() => _Reports(
            [
              _finding('x.err', Severity.error, 'lib/b.dart'),
              _finding('x.err', Severity.error, 'lib/c.dart'),
            ],
            ids: const ['x.err'],
          );

          // Three blocks of one set, then another set: three blocks again.
          expect(await runs('s', 3), [2, 2, 2]);
          for (final changed in [
            () => brokenFile(message: 'Different.'),
            () => brokenFile(file: 'lib/b.dart'),
            two,
          ]) {
            expect(
              [
                await call('s', checks: [changed()]),
                await call('s', checks: [changed()]),
                await call('s', checks: [changed()]),
              ],
              [2, 2, 2],
            );
          }
          // Only when the last set stays the same a fourth time does it go.
          expect(await call('s', checks: [two()]), 0);
        });

        test('an error that moves between lines is the same error: an edit '
            'above it does not reset the count', () async {
          expect(
            await call('s', active: false, checks: [brokenFile(line: 10)]),
            2,
          );
          expect(await call('s', checks: [brokenFile(line: 14)]), 2);
          expect(await call('s', checks: [brokenFile(line: 3)]), 2);
          expect(await call('s', checks: [brokenFile(line: 20)]), 0);
          // The message names the line it has now.
          expect(stopJson()['systemMessage'], contains('(line 20)'));
        });

        test('the count ends when the errors are gone: a clean Stop in the '
            'middle starts it again, and so do warnings alone', () async {
          expect(await runs('s', 2), [2, 2]);
          // Fixed.
          expect(await call('s', checks: const []), 0);
          // The same errors come back: three blocks again.
          expect(
            [await call('s'), await call('s'), await call('s')],
            [2, 2, 2],
          );
          expect(await call('s'), 0);
          // Warnings alone end it too.
          expect(
            await call(
              's',
              checks: [
                _Reports(
                  [_finding('x.warn', Severity.warning, 'lib/a.dart')],
                  ids: const ['x.warn'],
                ),
              ],
            ),
            0,
          );
          expect(
            [await call('s'), await call('s'), await call('s')],
            [2, 2, 2],
          );
        });

        test('two sessions keep separate counts', () async {
          expect(await call('one', active: false), 2);
          expect(await call('one'), 2);
          // The other session is continuing too, but has no count: its first.
          expect(await call('two'), 2);
          expect(await call('one'), 2);
          // The first reaches its limit; the second is at its first.
          expect(await call('one'), 0);
          expect(await call('two'), 2);
          expect(await call('two'), 2);
          expect(await call('two'), 0);
          // And the first is still let go, not reset by the other.
          expect(await call('one'), 0);
        });

        test('the edits between two Stop runs, and the after-edit hook '
            'that follows them, keep the count', () async {
          expect(await call('edits', active: false), 2);
          for (var i = 1; i <= 3; i++) {
            // The agent edits, and the PostToolUse hook runs (and saves its
            // fingerprint into the same record).
            File(
              p.join(project, 'lib', 'main.dart'),
            ).writeAsStringSync('void main() { print($i); }\n');
            expect(
              await hook(input: postInput('edits'), checks: [brokenFile()]),
              2,
            );
            expect(
              await call('edits', checks: [brokenFile(line: i + 1)]),
              i < 3 ? 2 : 0,
              reason: 'Stop after edit $i',
            );
          }
        });

        test('a run with no session never lets the agent go and keeps no '
            'record: Claude Code\'s own limit ends such a loop', () async {
          for (var i = 0; i < 6; i++) {
            expect(
              await stop(
                input: '{"stop_hook_active":true}',
                checks: [brokenFile()],
              ),
              2,
            );
          }
          expect(
            Directory(
              p.join(project, '.appstein', 'hook-sessions'),
            ).existsSync(),
            isFalse,
          );
        });

        test('a run in which Appstein failed changes nothing: the count '
            'goes on after it', () async {
          expect(await call('s', active: false), 2);
          expect(
            await stop(
              input: stopInput('s', active: true),
              scope: <T>(body) => throw StateError('it fell'),
            ),
            0,
          );
          expect(
            [await call('s'), await call('s'), await call('s')],
            [2, 2, 0],
          );
        });

        group('when the record can\'t be read or saved, the agent is '
            'blocked for longer, not let go early (but for one case)', () {
          /// Takes the records' lock.
          Future<KnowledgeLock> holdLock() => KnowledgeLock.acquire(
            HookSessions(
              project,
            ).folder.replaceFirst('${p.separator}records', ''),
          );

          test('the records\' lock stays busy for the whole wait: no count '
              'is saved, so the count stays at 1 and the agent is blocked, '
              'without an error', () async {
            final lock = await holdLock();
            try {
              for (var i = 0; i < 3; i++) {
                expect(await call('s', active: i > 0), 2, reason: 'run $i');
                expect(err.toString(), contains('error x.err'));
              }
            } finally {
              lock.release();
            }
            expect(HookSessions(project).readGuard('s'), isNull);
            // Once it is free the counting works again, from the start.
            expect(
              [
                await call('s'),
                await call('s'),
                await call('s'),
                await call('s'),
              ],
              [2, 2, 2, 0],
            );
          });

          test('the lock is busy for less than the Stop hook\'s wait: the '
              'count is saved after all (the after-edit hook\'s 200 ms '
              'would have lost it)', () async {
            final lock = await holdLock();
            Timer(const Duration(milliseconds: 700), lock.release);
            expect(await call('s', active: false), 2);
            expect(HookSessions(project).readGuard('s')!.count, 1);
          });

          test('the lock is busy at the fourth run: the decision was made '
              'from the count read, so the agent is let go', () async {
            expect(await runs('s', 3), [2, 2, 2]);
            final lock = await holdLock();
            try {
              expect(await call('s'), 0);
              expect(stopJson()['systemMessage'], contains('3 times in a row'));
            } finally {
              lock.release();
            }
          });

          test('the one way a release can come early: a save of a changed '
              'set fails even after the wait, so the old, higher count '
              'stays and the old errors coming back are counted on from '
              'it', () async {
            expect(await runs('s', 2), [2, 2]);
            // Another set blocks once, and its save fails.
            final lock = await holdLock();
            try {
              expect(
                await call('s', checks: [brokenFile(file: 'lib/other.dart')]),
                2,
              );
            } finally {
              lock.release();
            }
            expect(HookSessions(project).readGuard('s')!.count, 2);
            // The first errors return: counted on from 2, so the second of
            // them is the third block, and the next run lets go, after the
            // first errors blocked only three times with another between.
            expect(await call('s'), 2);
            expect(await call('s'), 0);
          });

          test('a record that is damaged counts as none: the count starts '
              'again and the agent is blocked', () async {
            expect(await runs('s', 2), [2, 2]);
            final record = Directory(
              HookSessions(project).folder,
            ).listSync().whereType<File>().single;
            record.writeAsStringSync('{ not json');
            // It is whole again, at 1.
            expect(
              [
                await call('s'),
                await call('s'),
                await call('s'),
                await call('s'),
              ],
              [2, 2, 2, 0],
            );
          });

          test('a folder that can\'t be written is no error: the agent is '
              'blocked every time', () async {
            // The records' folder is a file.
            final blocker = File(
              HookSessions(
                project,
              ).folder.replaceFirst('${p.separator}records', ''),
            )..writeAsStringSync('not a folder');
            expect(blocker.existsSync(), isTrue);
            for (var i = 0; i < 5; i++) {
              expect(await call('s', active: i > 0), 2, reason: 'run $i');
              expect(err.toString(), contains('error x.err'));
              expect(out.toString(), isEmpty);
            }
          });
        });
      });
    });

    group('when Appstein itself fails', () {
      /// Expects exit 0, the failure told to the agent and to the developer,
      /// with [reason] in both, and its details on stderr (Claude Code keeps
      /// stderr at exit 0 in its debug log only).
      void expectToldToBoth(int exitCode, String reason) {
        expect(exitCode, 0, reason: 'never exit 2 or 3 for it\n$err');
        expect(err.toString(), contains(reason));
        final json = stdoutJson();
        expect(json.keys.toSet(), {'hookSpecificOutput', 'systemMessage'});
        final output = json['hookSpecificOutput']! as Map<String, Object?>;
        expect(output['hookEventName'], 'PostToolUse');
        final forAgent = output['additionalContext']! as String;
        expect(forAgent, contains('unchecked'));
        expect(forAgent, contains(reason));
        final forDeveloper = json['systemMessage']! as String;
        expect(forDeveloper, contains(reason));
        expect(forDeveloper, contains('run `appstein doctor`'));
      }

      test('an analysis server that can\'t answer', () async {
        expectToldToBoth(
          await hook(
            analysis: ScriptedCodeAnalysis(
              failure: const CodeAnalysisException(
                'its analysis was not done within 180 s',
              ),
            ),
          ),
          'The Dart analysis server could not answer: its analysis was not '
          'done within 180 s.',
        );
      });

      test('an invalid appstein.yaml', () async {
        File(
          p.join(project, 'appstein.yaml'),
        ).writeAsStringSync('appstein: 99\n');
        expectToldToBoth(await hook(), 'Config format 99 is not supported');
      });

      test('no project', () async {
        expectToldToBoth(
          await hook(workingDirectory: work.path),
          'needs a Flutter project',
        );
      });

      test('a check that throws', () async {
        expectToldToBoth(
          await hook(checks: const [_Throws()]),
          'The check `boom.check` failed',
        );
      });

      test(
        'in the real binary: the input is read from stdin, the failure is '
        'exit 0 with the JSON on stdout and the details on stderr; stdin '
        'that is never closed is given up on after 2 s and the process '
        'still ends',
        () => withChildProcessesToItself(() async {
          // It starts processes, and other files' tests count this process's
          // children: one at a time.
          // The command that starts the guard starts this package's script.
          final start = analysisGuardCommand()..removeLast();
          Future<({int exit, Map<String, Object?> json, String stderr})>
          binary({required bool closeStdin}) async {
            final process = await Process.start(start.first, [
              ...start.skip(1),
              'verify',
              '--fast',
              '--hook',
              'claude',
            ], workingDirectory: work.path);
            final stdout = process.stdout.transform(utf8.decoder).join();
            final stderr = process.stderr.transform(utf8.decoder).join();
            process.stdin.write(_claudeInput);
            await process.stdin.flush();
            if (closeStdin) await process.stdin.close();
            final exit = await process.exitCode;
            // Only now, after the process ended with its input still open.
            if (!closeStdin) await process.stdin.close().catchError((_) {});
            return (
              exit: exit,
              json: jsonDecode(await stdout) as Map<String, Object?>,
              stderr: await stderr,
            );
          }

          final results = await Future.wait([
            binary(closeStdin: true),
            binary(closeStdin: false),
          ]);
          for (final run in results) {
            expect(run.exit, 0, reason: run.stderr);
            expect(run.stderr, contains('needs a Flutter project'));
            expect(run.json.keys.toSet(), {
              'hookSpecificOutput',
              'systemMessage',
            });
            expect(
              run.json['systemMessage'],
              contains('needs a Flutter project'),
            );
          }
        }),
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        'one answer only: an error that escapes every future while the run '
        'is going on, or just after it answered, never makes a second '
        'answer or changes the exit code given first',
        () => withChildProcessesToItself(() async {
          // The harness runs the command through `runGuarded`, as the binary
          // does, in a process of its own.
          final harness = p.join(
            Directory.current.path,
            'test',
            'support',
            'hook_race_harness.dart',
          );
          Future<ProcessResult> race(String order) => Process.run(
            Platform.resolvedExecutable,
            [harness, project, sdk, cache, order],
          );

          // The run answers exit 2 with the error, then a crash escapes: the
          // exit code stays 2, stdout stays empty, and the crash's trace is
          // not added to the errors on stderr.
          final answered = await race('answer-then-crash');
          expect(answered.exitCode, 2, reason: '${answered.stderr}');
          expect(answered.stdout, isEmpty);
          expect(answered.stderr, contains('error x.err'));
          expect(answered.stderr, isNot(contains('late crash')));

          // The crash escapes first, then the run would answer exit 2: the
          // failure JSON is the only document, the exit code stays 0, and
          // the errors are not added to stderr.
          final crashed = await race('crash-then-answer');
          expect(crashed.exitCode, 0, reason: '${crashed.stderr}');
          final json =
              jsonDecode(crashed.stdout as String) as Map<String, Object?>;
          expect(json.keys.toSet(), {'hookSpecificOutput', 'systemMessage'});
          expect(json['systemMessage'], contains('late crash'));
          expect(crashed.stderr, contains('late crash'));
          expect(crashed.stderr, isNot(contains('error x.err')));

          // The run answers exit 2, then an error escapes whose text can't
          // even be had: the exit code given first still stands.
          final unsayable = await race('answer-then-unsayable-crash');
          expect(unsayable.exitCode, 2, reason: '${unsayable.stderr}');
          expect(unsayable.stdout, isEmpty);
          expect(unsayable.stderr, contains('error x.err'));
        }),
        timeout: const Timeout(Duration(minutes: 5)),
      );

      test('a usage error in hook mode is still exit 3', () async {
        expect(
          await hook(extra: ['--files', '../x.dart']),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('outside the project'));
      });

      test('any other failure, with its stack trace on stderr', () async {
        expectToldToBoth(
          await hook(scope: <T>(body) => throw StateError('it fell')),
          'Appstein failed unexpectedly: Bad state: it fell',
        );
        expect(err.toString(), contains('#0'));
        // The trace is for a bug report: the agent and the developer are
        // not shown it.
        expect(out.toString(), isNot(contains('#0')));
      });

      test('a failure that is no bug has no trace, and says to run '
          '`appstein doctor`', () async {
        await hook(
          analysis: ScriptedCodeAnalysis(
            failure: const CodeAnalysisException('it ended'),
          ),
        );
        expect(
          err.toString(),
          'The Dart analysis server could not answer: it ended.\n'
          'Run `appstein doctor` to check your setup.\n',
        );
      });

      test('before the command runs: an environment that can\'t be built '
          'is told the same way, with `--hook claude` and `--hook=claude`; '
          'without --hook it is exit 3', () async {
        for (final flags in [
          ['--hook', 'claude'],
          ['--hook=claude'],
        ]) {
          out.clear();
          err.clear();
          final code = await runAppstein(
            ['verify', '--fast', ...flags],
            out: out,
            err: err,
            environmentFactory: () =>
                throw const FileSystemException('cwd gone'),
          );
          expect(code, 0, reason: '$flags');
          expect(
            stdoutJson()['systemMessage'],
            allOf(contains('cwd gone'), contains('run `appstein doctor`')),
          );
          expect(context(), contains('unchecked'));
          expect(err.toString(), contains('Appstein failed unexpectedly'));
          expect(err.toString(), contains('#0'));
        }
        out.clear();
        err.clear();
        expect(
          await runAppstein(
            ['verify', '--fast'],
            out: out,
            err: err,
            environmentFactory: () => throw const FileSystemException('x'),
          ),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
      });
    });

    group('when the notices of the run have something to tell', () {
      const notice =
          'Process 7 (dart.exe) may be an analysis server that Appstein '
          'started and could not stop. End it with `taskkill /PID 7 /F`.';

      test('they reach the developer as the systemMessage: alone, with '
          'warnings, and beside the errors of exit 2', () async {
        final analysis = ScriptedCodeAnalysis(notices: const [notice]);
        // Nothing else to say: the message alone.
        expect(await hook(analysis: analysis), 0);
        expect(stdoutJson(), {'systemMessage': 'Appstein note: $notice'});
        expect(err.toString(), isEmpty);

        // With a warning (in a file the run was told to check): the agent
        // gets it, the developer the note.
        const warning = CodeDiagnostic(
          file: 'lib/main.dart',
          line: 2,
          code: 'unused_import',
          message: 'Unused import.',
          level: DiagnosticLevel.warning,
        );
        out.clear();
        expect(
          await hook(
            extra: ['--files', 'lib/main.dart'],
            analysis: ScriptedCodeAnalysis(
              notices: const [notice],
              found: const [warning],
            ),
          ),
          0,
        );
        expect(stdoutJson().keys.toSet(), {
          'hookSpecificOutput',
          'systemMessage',
        });
        expect(context(), contains('warning dart.warning (line 2)'));
        expect(context(), isNot(contains('Process 7')));

        // With an error: exit 2 and the error on stderr; the JSON fields
        // are still read at exit 2 (Claude Code's docs), so the note is on
        // stdout.
        out.clear();
        err.clear();
        expect(
          await hook(
            analysis: ScriptedCodeAnalysis(
              notices: const [notice],
              found: const [
                CodeDiagnostic(
                  file: 'lib/main.dart',
                  line: 1,
                  code: 'undefined_method',
                  message: 'No such method.',
                  level: DiagnosticLevel.error,
                ),
              ],
            ),
          ),
          2,
        );
        expect(stdoutJson(), {'systemMessage': 'Appstein note: $notice'});
        expect(err.toString(), contains('error dart.error (line 1)'));
        expect(err.toString(), isNot(contains('Process 7')));
      });
    });

    group('the 10,000 character limit', () {
      void expectUnderLimit(Iterable<String> texts) {
        for (final text in texts) {
          expect(text.length, lessThan(10000));
          expect(text, contains('…(cut)'));
        }
      }

      Iterable<String> jsonTexts() {
        final json = stdoutJson();
        return [
          if (json['hookSpecificOutput'] case final Map<String, Object?> o)
            o['additionalContext']! as String,
          if (json['systemMessage'] case final String message) message,
        ];
      }

      test('a warning of 12,000 characters is cut in the context', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  _finding(
                    'x.warn',
                    Severity.warning,
                    'lib/c.dart',
                    line: 3,
                    message: 'W' * 12000,
                    fix: 'F' * 12000,
                    ref: 'R' * 12000,
                  ),
                ],
                ids: const ['x.warn'],
              ),
            ],
          ),
          0,
        );
        expectUnderLimit(jsonTexts());
        // What is kept is the start, so the agent can still tell what it is.
        expect(context(), contains('warning x.warn (line 3): WWWW'));
        expect(context(), contains('lib/c.dart'));
      });

      test('an error of 12,000 characters is cut on stderr', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  _finding(
                    'x.err',
                    Severity.error,
                    'lib/${'d' * 12000}.dart',
                    line: 3,
                    message: 'E' * 12000,
                    fix: 'F' * 12000,
                    ref: 'R' * 12000,
                  ),
                ],
                ids: const ['x.err'],
              ),
            ],
          ),
          2,
        );
        expectUnderLimit([err.toString()]);
        expect(err.toString(), contains('error x.err (line 3): EEEE'));
      });

      test('many long errors and checks that did not run stay under the '
          'limit together', () async {
        expect(
          await hook(
            checks: [
              _Reports(
                [
                  for (var i = 0; i < 40; i++)
                    _finding(
                      'x.err',
                      Severity.error,
                      'lib/f$i.dart',
                      message: 'E' * 3000,
                    ),
                ],
                ids: const ['x.err'],
              ),
              for (var i = 0; i < 30; i++) _NotRunCheck('y.slow$i', 'S' * 3000),
            ],
          ),
          2,
        );
        expect(err.toString().length, lessThan(10000));
        expect(err.toString(), contains('y.slow0'));
        expect(err.toString(), contains('…(cut)'));
      });

      test('many checks that did not run, with long reasons, stay under the '
          'limit in the context', () async {
        expect(
          await hook(
            checks: [
              for (var i = 0; i < 30; i++) _NotRunCheck('y.slow$i', 'S' * 3000),
            ],
          ),
          0,
        );
        expectUnderLimit(jsonTexts());
      });

      test('a failure reason of 15,000 characters is cut in the context and '
          'the message, and the details on stderr keep all of it', () async {
        expect(
          await hook(scope: <T>(body) => throw StateError('X' * 15000)),
          0,
        );
        expectUnderLimit(jsonTexts());
        expect(jsonTexts(), hasLength(2));
        expect(err.toString().length, greaterThan(15000));
      });

      test('a cut never splits a character outside the basic plane', () async {
        for (final start in ['', 'a']) {
          out.clear();
          await hook(
            checks: [
              _Reports(
                [
                  _finding(
                    'x.warn',
                    Severity.warning,
                    'lib/c.dart',
                    message: '$start${'\u{1F600}' * 3000}',
                  ),
                ],
                ids: const ['x.warn'],
              ),
            ],
          );
          final text = context();
          final at = text.indexOf('…(cut)');
          expect(at, greaterThan(0), reason: 'start "$start"');
          final before = text.codeUnitAt(at - 1);
          expect(before & 0xFC00, isNot(0xD800), reason: 'start "$start"');
        }
      });
    });
  });

  group('HookAnswer', () {
    const blocked = HookReply(
      exitCode: 2,
      stderr: 'the errors\n',
      isFailure: false,
    );
    const failed = HookReply(
      exitCode: 0,
      stdout: '{"systemMessage":"x"}\n',
      stderr: 'the details\n',
      isFailure: true,
    );

    test('the first reply is written whole and its exit code stands', () {
      final answer = HookAnswer();
      final out = StringBuffer();
      final err = StringBuffer();
      expect(answer.answered, isFalse);
      expect(answer.write(blocked, out, err), 2);
      expect(answer.answered, isTrue);
      expect(out.toString(), isEmpty);
      expect(err.toString(), 'the errors\n');
      // A failure reply after exit 2 writes nothing and returns 2.
      expect(answer.write(failed, out, err), 2);
      expect(out.toString(), isEmpty);
      expect(err.toString(), 'the errors\n');
    });

    test('after a first reply of exit 0 a later one writes only the details '
        'of a failure to stderr, and the first exit code stands', () {
      final answer = HookAnswer();
      final out = StringBuffer();
      final err = StringBuffer();
      expect(answer.write(failed, out, err), 0);
      expect(out.toString(), '{"systemMessage":"x"}\n');
      expect(err.toString(), 'the details\n');
      // Exit 2 would have blocked; the first answer was exit 0.
      expect(answer.write(blocked, out, err), 0);
      expect(answer.write(failed, out, err), 0);
      expect(out.toString(), '{"systemMessage":"x"}\n');
      expect(err.toString(), 'the details\nthe details\n');
    });

    test('its exit code is null before a reply and the first one after', () {
      final answer = HookAnswer();
      expect(answer.exitCode, isNull);
      answer.write(blocked, StringBuffer(), StringBuffer());
      answer.write(failed, StringBuffer(), StringBuffer());
      expect(answer.exitCode, 2);
    });
  });

  group('claudeHookKind', () {
    test('is the after-edit hook for verify --fast with --hook claude or '
        '--hook=claude', () {
      expect(
        claudeHookKind(['verify', '--fast', '--hook', 'claude']),
        HookKind.afterEdit,
      );
      expect(
        claudeHookKind(['verify', '--hook=claude', '--fast']),
        HookKind.afterEdit,
      );
    });

    test('is the Stop hook for a hook run that is not fast: --full, --apply '
        'or neither flag', () {
      expect(
        claudeHookKind(['verify', '--full', '--hook', 'claude']),
        HookKind.stop,
      );
      expect(claudeHookKind(['verify', '--hook=claude']), HookKind.stop);
      expect(
        claudeHookKind(['verify', '--full', '--apply', '--hook', 'claude']),
        HookKind.stop,
      );
    });

    test('is null without verify, for another agent, for no --hook, and for '
        'words after --, which are no options', () {
      expect(claudeHookKind(['sync', '--hook', 'claude']), isNull);
      expect(claudeHookKind(['verify', '--hook', 'codex']), isNull);
      expect(claudeHookKind(['verify', '--full']), isNull);
      expect(claudeHookKind(['verify', '--', '--hook', 'claude']), isNull);
      expect(claudeHookKind(['--', 'verify', '--hook=claude']), isNull);
      // A --fast after -- is no option either.
      expect(
        claudeHookKind(['verify', '--hook', 'claude', '--', '--fast']),
        HookKind.stop,
      );
    });
  });

  group('hookKindOf', () {
    HookInput input(String? event) => HookInput(eventName: event);

    test('the event the input names decides: Stop is the Stop hook, any '
        'other event the after-edit hook, whatever the flags say', () {
      for (final fast in [true, false]) {
        expect(
          hookKindOf(input('Stop'), fast: fast),
          HookKind.stop,
          reason: 'fast $fast',
        );
        for (final event in [
          'PostToolUse',
          'SubagentStop',
          'UserPromptSubmit',
        ]) {
          expect(
            hookKindOf(input(event), fast: fast),
            HookKind.afterEdit,
            reason: '$event, fast $fast',
          );
        }
      }
    });

    test('with no event in the input the flags decide', () {
      expect(hookKindOf(input(null), fast: true), HookKind.afterEdit);
      expect(hookKindOf(input(null), fast: false), HookKind.stop);
      expect(hookKindOf(const HookInput(), fast: false), HookKind.stop);
    });
  });

  group('readStdinText', () {
    test('reads the input to its end', () async {
      final text = await readStdinText(
        source: Stream.fromIterable([
          utf8.encode('{"session_id"'),
          utf8.encode(':"s"} é'),
        ]),
      );
      expect(text, '{"session_id":"s"} é');
    });

    test('goes on without input once the limit is up, and gives up the '
        'stream', () async {
      final controller = StreamController<List<int>>();
      var cancelled = false;
      controller.onCancel = () => cancelled = true;
      final watch = Stopwatch()..start();
      final text = await readStdinText(
        source: controller.stream,
        limit: const Duration(milliseconds: 100),
      );
      expect(text, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(cancelled, isTrue);
      await controller.close();
    });

    test('a stream that fails is no input', () async {
      expect(
        await readStdinText(source: Stream.error(StateError('closed'))),
        isEmpty,
      );
    });

    test('the limit is 2 s', () {
      expect(hookInputLimit, const Duration(seconds: 2));
    });
  });
}

/// A check that names itself as not run.
final class _NotRunCheck implements VerifyCheck {
  _NotRunCheck(this.id, this.reason);

  final String id;
  final String reason;

  @override
  List<String> get ids => [id];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    context.notRun(id, reason);
    return const [];
  }
}
