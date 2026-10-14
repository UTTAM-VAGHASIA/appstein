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

Future<void> main(List<String> arguments) async {
  final scenario = arguments.first;
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
