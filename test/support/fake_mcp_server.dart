// A minimal MCP server for the tests of tool/src/mcp_session.dart and
// tool/src/warm_measurement.dart: it answers `initialize` and `tools/call`,
// one JSON-RPC message per line, and ends when its input closes.
//
// Tools: `echo` answers with the arguments; `fail` answers with `isError`;
// `die` ends the process without answering; `hang` never answers; `garbage`
// writes a line that is not JSON; `badresult` answers with a result that is
// not an object; `overview` answers; `verify` answers like the real one for
// a project, see below.
//
// Flags:
// - `--stubborn`: the process does not end when its input closes, so a test
//   can see the session end it.
// - `--file <path> --name <relative>`: `verify` reads the Dart file at
//   <path> and reports a `dart.error` finding on <name> for each line that
//   starts with `int wrong`, with its line number: the server reads the
//   file as it is on disk, as a correct analysis server does.
// - `--sticky-line`: the error is reported on the first line it was ever
//   reported on, whatever line it is on now: an answer about an old edit.
// - `--blind`: `verify` reports no error at all, whatever the file holds.
// - `--stale-after <n>`: from the nth `verify` call on, `verify` answers
//   with its last answer again, whatever the file holds.
// - `--slow-ms <n>`: `verify` waits n milliseconds before it answers.
// - `--error-reply-at <n>`: the nth `verify` call answers with `isError`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  String? flag(String name) {
    final at = arguments.indexOf(name);
    return at < 0 || at + 1 >= arguments.length ? null : arguments[at + 1];
  }

  final stubborn = arguments.contains('--stubborn');
  final blind = arguments.contains('--blind');
  final file = flag('--file');
  final name = flag('--name');
  final staleAfter = int.tryParse(flag('--stale-after') ?? '');
  final slow = int.tryParse(flag('--slow-ms') ?? '') ?? 0;
  final errorAt = int.tryParse(flag('--error-reply-at') ?? '');
  final sticky = arguments.contains('--sticky-line');
  int? firstLine;
  var verifies = 0;
  Map<String, Object?>? lastVerify;

  Map<String, Object?> verify() {
    verifies++;
    if (errorAt == verifies) {
      return {
        'isError': true,
        'content': [
          {'type': 'text', 'text': 'The analysis server is gone.'},
        ],
      };
    }
    if (staleAfter != null && verifies >= staleAfter && lastVerify != null) {
      return lastVerify!;
    }
    final findings = <Map<String, Object?>>[];
    if (!blind && file != null && name != null) {
      final lines = File(file).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('int wrong')) {
          // `--sticky-line` names the first line it ever reported.
          if (sticky) firstLine ??= i + 1;
          findings.add({
            'id': 'dart.error',
            'file': name,
            'line': sticky ? firstLine : i + 1,
            'message': "A value of type 'String' can't be returned.",
          });
        }
      }
    }
    return lastVerify = {
      'isError': false,
      'content': [
        {'type': 'text', 'text': 'Fast verify.'},
      ],
      'structuredContent': {'findings': findings},
    };
  }

  // Noise on stderr, which a session must drain or the server would block.
  stderr.writeln('fake mcp server started');
  // A notification before any request, which a session must skip.
  stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/x'}));
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final message = jsonDecode(line) as Map<String, Object?>;
    final id = message['id'];
    if (id == null) continue;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    Object? result;
    switch (message['method']) {
      case 'initialize':
        result = {'serverInfo': 'fake'};
      case 'tools/call':
        final tool = params!['name'];
        switch (tool) {
          case 'die':
            exit(3);
          case 'hang':
            continue;
          case 'garbage':
            stdout.writeln('this is not json');
            continue;
          case 'badresult':
            result = 'text';
          case 'fail':
            result = {
              'isError': true,
              'content': [
                {'type': 'text', 'text': 'It failed.'},
              ],
            };
          case 'overview':
            result = {
              'isError': false,
              'structuredContent': {'index': 'INDEX'},
            };
          case 'verify':
            if (slow > 0) {
              await Future<void>.delayed(Duration(milliseconds: slow));
            }
            result = verify();
          default:
            result = {
              'isError': false,
              'structuredContent': {'echo': params['arguments']},
            };
        }
      default:
        stdout.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'no such method'},
          }),
        );
        continue;
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }
  // A timer keeps the process alive after its input has closed.
  if (stubborn) Timer.periodic(const Duration(hours: 1), (_) {});
}
