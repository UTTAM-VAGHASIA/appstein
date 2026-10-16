// A guard with a scripted server behind it, for what a real analysis server
// can't be made to do on demand. Its first argument names the scenario (see
// `main`; `log:<file>` and any other name analyze nothing and answer every
// request); the `dart` executable `AnalysisServer` adds is ignored. It speaks
// the legacy analyzer protocol as far as `AnalysisServer` uses it, names
// itself as both processes, and ends in order on `server.shutdown` or when
// its stdin closes.

import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_guard.dart';
import 'package:path/path.dart' as p;

void _send(Map<String, Object?> message) => stdout.writeln(jsonEncode(message));

void _event(String name, Map<String, Object?> params) =>
    _send({'event': name, 'params': params});

void _status(bool analyzing) => _event('server.status', {
  'analysis': {'isAnalyzing': analyzing},
});

Map<String, Object?> _diagnostic(
  String file,
  String code, {
  String severity = 'ERROR',
  String type = 'COMPILE_TIME_ERROR',
  int line = 1,
}) => {
  'severity': severity,
  'type': type,
  'location': {
    'file': file,
    'offset': 0,
    'length': 1,
    'startLine': line,
    'startColumn': 1,
  },
  'message': 'About $code.',
  'code': code,
};

void _errors(String file, List<Map<String, Object?>> errors) =>
    _event('analysis.errors', {'file': file, 'errors': errors});

/// The `fixes-<how>@<log file>` scenarios: five files, `lib/a.dart` to
/// `lib/e.dart`, analyzed with no diagnostic. The first `edit.bulkFixes`
/// rewrites the start of `a.dart` (`int` to `num`) and counts two fixes of
/// `x_code` there; what the next pass does is `<how>`: `done` finds none,
/// `refuse` is refused, `silent` is never answered, and `forever` finds the
/// same fix again every time. Three more find none in the next pass but
/// treat the overlays otherwise: `deafadd` never answers an overlay's
/// `add`, `deafremove` never answers a `remove` once a pass has been asked,
/// and `refuseadd` refuses the `add`. `edit.format` answers that every file but `a.dart` would get
/// a `// formatted` line at its start. Every request after the start is
/// noted in the log file, one line each, with the change and the files of
/// an `analysis.updateContent`.
Future<void> _fixes(
  Map<String, Object?> request,
  String how,
  String log,
  String root,
  int passes,
) async {
  final id = request['id'];
  final params = request['params'] as Map<String, Object?>?;
  String named(String file) => p.split(p.relative(file, from: root)).join('/');
  final noted = switch (params) {
    {'files': final Map<String, Object?> files} =>
      ' ${files.entries.map((file) => '${(file.value! as Map)['type']} ${named(file.key)}').join(', ')}',
    {'file': final String file} => ' ${named(file)}',
    _ => '',
  };
  File(
    log,
  ).writeAsStringSync('${request['method']}$noted\n', mode: FileMode.append);
  switch (request['method']) {
    case 'edit.bulkFixes':
      final a = p.join(root, 'lib', 'a.dart');
      final again = passes > 1;
      if (again && how == 'silent') return;
      if (again && how == 'refuse') {
        _send({
          'id': id,
          'error': {'code': 'SERVER_ERROR', 'message': 'The fix threw.'},
        });
        return;
      }
      final none = again && how != 'forever';
      _send({
        'id': id,
        'result': {
          'edits': [
            if (!none)
              {
                'file': a,
                'fileStamp': 0,
                'edits': [
                  // `forever` rewrites the same word back and forth.
                  {
                    'offset': 0,
                    'length': 3,
                    'replacement': passes.isOdd ? 'num' : 'int',
                  },
                ],
              },
          ],
          'details': [
            if (!none)
              {
                'path': a,
                'fixes': [
                  {'code': 'x_code', 'occurrences': 2},
                ],
              },
          ],
        },
      });
    case 'edit.format':
      final file = params!['file']! as String;
      _send({
        'id': id,
        'result': {
          'edits': [
            if (!file.endsWith('a.dart'))
              {'offset': 0, 'length': 0, 'replacement': '// formatted\n'},
          ],
          'selectionOffset': 0,
          'selectionLength': 0,
        },
      });
    case 'analysis.updateContent':
      final types = {
        for (final change in (params!['files']! as Map).values)
          (change! as Map)['type'],
      };
      if (how == 'deafadd' && types.contains('add')) return;
      // Only once a pass has made an overlay: a reading tells files with
      // `remove` too.
      if (how == 'deafremove' && types.contains('remove') && passes > 0) {
        return;
      }
      if (how == 'refuseadd' && types.contains('add')) {
        _send({
          'id': id,
          'error': {'code': 'INVALID_OVERLAY_CHANGE', 'message': 'No.'},
        });
        return;
      }
      _send({'id': id});
    default:
      _send({'id': id});
  }
}

Future<void> main(List<String> arguments) async {
  final scenario = arguments.first;
  final fixes = RegExp(r'^fixes-(\w+)@(.+)$').firstMatch(scenario);
  var fixRoot = '';
  var bulkFixes = 0;
  // `crash:<process ID>`, `names:<process ID>` and `deaf:<process ID>` name
  // that process as the server. `names:` then answers every request and
  // analyzes nothing; `deaf:` does the same, but ends neither when asked to
  // stop nor when its input closes, so only a kill ends it. `never` says
  // it is analyzing and never that it is done.
  final named = RegExp(r'^(crash|names|deaf):(\d+)$').firstMatch(scenario);
  final server = named?.group(2) ?? '$pid';
  final deaf = scenario.startsWith('deaf:');
  stderr.writeln('$analysisGuardSign$pid $server');
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final request = jsonDecode(line) as Map<String, Object?>;
    final id = request['id'];
    if (fixes != null && fixRoot.isNotEmpty) {
      if (request['method'] == 'edit.bulkFixes') bulkFixes++;
      await _fixes(
        request,
        fixes.group(1)!,
        fixes.group(2)!,
        fixRoot,
        bulkFixes,
      );
      continue;
    }
    switch (request['method']) {
      case 'server.shutdown' when deaf:
        continue;
      case 'server.shutdown':
        _send({'id': id});
        await stdout.flush();
        stderr.writeln(analysisGuardEnded);
        await stderr.flush();
        exit(0);
      case 'analysis.setAnalysisRoots':
        final root =
            ((request['params']! as Map)['included']! as List).single as String;
        String inProject(String relative) =>
            p.joinAll([root, ...relative.split('/')]);
        if (scenario == 'refuse') {
          _send({
            'id': id,
            'error': {
              'code': 'INVALID_FILE_PATH_FORMAT',
              'message': 'The root is not a path the server knows.',
            },
          });
          continue;
        }
        // A server that dies with its last words unfinished: no newline
        // ends them, so the guard's own last line arrives glued to them.
        // The guard names the process in `crash:<process ID>` as its
        // server, so the test can see that nothing ends that process.
        if (scenario.startsWith('crash:')) {
          stderr
            ..write('Out of memory in the middle of a wor')
            ..writeln(analysisGuardEnded);
          await stderr.flush();
          exit(7);
        }
        _send({'id': id});
        _status(true);
        if (fixes != null) {
          fixRoot = root;
          for (final name in ['a', 'b', 'c', 'd', 'e']) {
            _errors(inProject('lib/$name.dart'), []);
          }
        }
        switch (scenario) {
          // A file whose results the server takes back.
          case 'flush':
            _errors(inProject('lib/kept.dart'), [
              _diagnostic(inProject('lib/kept.dart'), 'kept'),
            ]);
            _errors(inProject('lib/gone.dart'), [
              _diagnostic(inProject('lib/gone.dart'), 'gone'),
            ]);
            _event('analysis.flushResults', {
              'files': [inProject('lib/gone.dart')],
            });
          // A file outside the project, as for a package it depends on.
          case 'outside':
            final outside = p.join(p.dirname(root), 'elsewhere', 'out.dart');
            _errors(inProject('lib/in.dart'), [
              _diagnostic(inProject('lib/in.dart'), 'inside'),
            ]);
            _errors(outside, [_diagnostic(outside, 'outside')]);
          // A diagnostic without its location.
          case 'malformed':
            _errors(inProject('lib/bad.dart'), [
              {'severity': 'ERROR', 'code': 'x', 'message': 'No location.'},
            ]);
          // The three levels of a TODO comment, and a lint of info level.
          case 'todo':
            final file = inProject('lib/a.dart');
            _errors(file, [
              _diagnostic(file, 'todo', severity: 'INFO', type: 'TODO'),
              _diagnostic(
                file,
                'fixme',
                severity: 'WARNING',
                type: 'TODO',
                line: 2,
              ),
              _diagnostic(
                file,
                'hack',
                severity: 'ERROR',
                type: 'TODO',
                line: 3,
              ),
              _diagnostic(
                file,
                'prefer_this',
                severity: 'INFO',
                type: 'LINT',
                line: 4,
              ),
            ]);
          // A plugin that could not be set up, told twice.
          case 'plugin':
            for (var i = 0; i < 2; i++) {
              _event('server.pluginError', {
                'message':
                    'An error occurred while setting up the analyzer plugin '
                    'package at X. The `dart pub upgrade` command failed:\n'
                    '  exitCode = 66\n'
                    '  stderr = version solving failed.\n\n'
                    '#0      PluginManager._compile (plugin_manager.dart:1)\n'
                    '#1      main (main.dart:2)\n',
              });
            }
          // The server says it can't go on, and never says it is done.
          case 'fatal':
            _event('server.error', {
              'isFatal': true,
              'message': 'Out of memory.\nNothing more can be analyzed.',
              'stackTrace': '#0 main',
            });
            continue;
          // Four files with no diagnostic, for `edit.format` (see below).
          case 'format':
            for (final name in ['a', 'b', 'c', 'd', 'e']) {
              _errors(inProject('lib/$name.dart'), []);
            }
          // An analysis that never ends.
          case 'never':
            continue;
          // An analysis that takes a while.
          case 'slow':
            await Future<void>.delayed(const Duration(milliseconds: 1500));
            _errors(inProject('lib/slow.dart'), [
              _diagnostic(inProject('lib/slow.dart'), 'slow'),
            ]);
        }
        _status(false);
      // `format`: `a.dart` would change, `d.dart` would not, the formatter
      // throws on `b.dart` (the server refuses with `SERVER_ERROR`), `e.dart`
      // does not parse (`FORMAT_WITH_ERRORS`), and `c.dart` is never
      // answered.
      case 'edit.format' when scenario == 'format':
        final file = (request['params']! as Map)['file']! as String;
        if (file.endsWith('b.dart')) {
          _send({
            'id': id,
            'error': {
              'code': 'SERVER_ERROR',
              'message': 'Error during `edit.format`: the formatter threw.',
            },
          });
        } else if (file.endsWith('e.dart')) {
          // A file that does not parse.
          _send({
            'id': id,
            'error': {
              'code': 'FORMAT_WITH_ERRORS',
              'message':
                  'Error during `edit.format`: source contains syntax '
                  'errors.',
            },
          });
        } else if (!file.endsWith('c.dart')) {
          _send({
            'id': id,
            'result': {
              'edits': file.endsWith('a.dart')
                  ? [
                      {'offset': 0, 'length': 1, 'replacement': 'x'},
                    ]
                  : <Object?>[],
              'selectionOffset': 0,
              'selectionLength': 0,
            },
          });
        }
      default:
        // `log:<file>`: each later request is noted in that file, one line
        // each, with the files it names.
        if (scenario.startsWith('log:') &&
            request['method'] != 'server.setSubscriptions') {
          final params = request['params'] as Map<String, Object?>?;
          final named = switch (params) {
            {'files': final Map<String, Object?> files} =>
              ' ${files.values.map((change) => (change! as Map)['type']).toSet().join('/')} '
                  '${files.keys.join(', ')}',
            {'file': final String file} => ' $file',
            _ => '',
          };
          File(scenario.substring('log:'.length)).writeAsStringSync(
            '${request['method']}$named\n',
            mode: FileMode.append,
          );
        }
        _send({'id': id});
    }
  }
  // Its stdin closed.
  if (deaf) {
    // Until it is killed.
    await Future<void>.delayed(const Duration(hours: 1));
  }
  stderr.writeln(analysisGuardEnded);
}
