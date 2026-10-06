import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../decisions/support/decision_files.dart';
import '../support/temp.dart';
import 'support/mcp_support.dart';

void main() {
  late String root;

  setUp(() {
    root = tempDir().path;
    handDecision(
      root,
      '0001-state.md',
      title: 'State management with provider',
      paths: ['lib/ui/**/view_models/**', 'lib/config/dependencies.dart'],
      why: 'Flutter recommends it.',
    );
    handDecision(
      root,
      '0002-routing.md',
      title: 'Routing with go_router',
      status: 'proposed',
      paths: ['lib/routing'],
      why: 'Deep links need declarative routes.',
    );
    handDecision(
      root,
      '0003-http.md',
      title: 'HTTP with dio',
      status: 'superseded',
      why: 'Interceptors.',
    );
    handDecision(
      root,
      '0004-http.md',
      title: 'HTTP with package http',
      supersedes: '0003',
      why: 'Fewer dependencies; state is not involved.',
    );
  });

  ToolReply ask([String? topic]) {
    final answer = decisionsInfo(readDecisions(root), topic: topic);
    expect(answer, isA<ToolReply>());
    final reply = answer as ToolReply;
    expectMatchesSchema(ToolSchemas.decisionsResult, reply.result);
    expect(withoutNulls(reply.result), reply.result);
    return reply;
  }

  List<String?> numbers(ToolReply reply) => [
    for (final decision in reply.result['decisions']! as List)
      (decision as Map)['number'] as String?,
  ];

  test('without a topic: every decision in force, in full, and a count of '
      'the superseded ones', () {
    final reply = ask();
    expect(reply.result['mode'], 'all');
    expect(numbers(reply), ['0001', '0002', '0004']);
    expect(reply.result['superseded'], 1);
    expect((reply.result['decisions']! as List).first, {
      'number': '0001',
      'title': 'State management with provider',
      'status': 'accepted',
      'date': '2026-10-01',
      'why': 'Flutter recommends it.',
      'paths': ['lib/ui/**/view_models/**', 'lib/config/dependencies.dart'],
      'checks': <String>[],
      'file': '.appstein/decisions/0001-state.md',
    });
    expect(
      reply.summary,
      '3 decisions are in force (2 accepted, 1 proposed); a proposed one '
      'binds only once the user accepts it. 1 is superseded.',
    );
    expect(ask('  ').result['mode'], 'all');
  });

  test('with no decisions at all it says so', () {
    final reply = decisionsInfo(const DecisionSet()) as ToolReply;
    expect(reply.result['decisions'], isEmpty);
    expect(reply.summary, 'No decisions are recorded yet.');
  });

  test('with a file path: the decisions in force whose paths cover it', () {
    final reply = ask('lib/ui/home/view_models/home_viewmodel.dart');
    expect(reply.result['mode'], 'path');
    expect(
      reply.result['topic'],
      'lib/ui/home/view_models/home_viewmodel.dart',
    );
    expect(numbers(reply), ['0001']);
    expect(reply.result['withoutPaths'], 1);
    expect(
      reply.summary,
      '1 decision covers lib/ui/home/view_models/home_viewmodel.dart. 1 more '
      'lists no paths and applies everywhere; call decisions() without a '
      'topic to read it.',
    );
  });

  test('a Windows path, a leading ./ and a folder pattern all match', () {
    expect(numbers(ask(r'lib\config\dependencies.dart')), ['0001']);
    expect(numbers(ask('./lib/config/dependencies.dart')), ['0001']);
    // `lib/routing` names a folder: it covers the files below it.
    expect(numbers(ask('lib/routing/router.dart')), ['0002']);
    expect(numbers(ask('lib/routing')), ['0002']);
    expect(numbers(ask('lib/routing_extra/x.dart')), isEmpty);
  });

  test('a path nothing covers says so', () {
    final reply = ask('pubspec.yaml');
    expect(reply.result['mode'], 'path');
    expect(numbers(reply), isEmpty);
    expect(
      reply.summary,
      "No decision's paths cover pubspec.yaml. 1 more lists no paths and "
      'applies everywhere; call decisions() without a topic to read it.',
    );
  });

  test('a path pattern that is not a valid glob never matches and is '
      'named', () {
    handDecision(root, '0005-bad.md', paths: ['"lib/{a"']);
    final reply = ask('lib/a/x.dart');
    expect(numbers(reply), isEmpty);
    expect(reply.result['problems'], [
      'Decision 0005 has a path pattern that is not valid: `lib/{a`.',
    ]);
  });

  test('with words: the decisions that mention them, best match first, '
      'superseded ones marked with what replaced them', () {
    final reply = ask('HTTP');
    expect(reply.result['mode'], 'words');
    expect(numbers(reply), ['0004', '0003']);
    final old = (reply.result['decisions']! as List).last as Map;
    expect(old['status'], 'superseded');
    expect(old['supersededBy'], '0004');
    expect(old['score'], 3);
    expect(reply.summary, '2 decisions match "HTTP".');
  });

  test('a word scores by where it is found: title 3, a path 2, the reason '
      '1; a score of two words is their sum', () {
    // "state": the title of 0001 (3) and the reason of 0004 (1).
    final state = ask('state');
    expect(numbers(state), ['0001', '0004']);
    expect(
      [
        for (final one in state.result['decisions']! as List)
          (one as Map)['score'],
      ],
      [3, 1],
    );
    // "routing": title (3), not counted again for the path.
    expect(
      (ask('routing').result['decisions']! as List).single,
      containsPair('score', 3),
    );
    // "dependencies": a path of 0001 (2), the reason of 0004 (1).
    expect(numbers(ask('dependencies')), ['0001', '0004']);
    expect(numbers(ask('state dependencies')), ['0001', '0004']);
    expect(
      (ask('state dependencies').result['decisions']! as List).first,
      containsPair('score', 5),
    );
  });

  test('a number finds its decision first', () {
    expect(numbers(ask('0002')).first, '0002');
    expect(numbers(ask('decision 2')).first, '0002');
  });

  test('words nothing mentions say so', () {
    final reply = ask('riverpod');
    expect(numbers(reply), isEmpty);
    expect(reply.summary, 'No decision matches "riverpod".');
  });

  test('a decision only a later one marks as superseded shows both '
      'statuses', () {
    handDecision(root, '0006-state.md', title: 'State again', supersedes: '1');
    final reply = ask('provider');
    final old = (reply.result['decisions']! as List).single as Map;
    expect(old['number'], '0001');
    expect(old['status'], 'superseded');
    expect(old['statusInFile'], 'accepted');
    expect(old['supersededBy'], '0006');
  });

  test('unreadable files and duplicate numbers are reported in every '
      'reply', () {
    File(
      p.join(root, '.appstein', 'decisions', '0007-x.md'),
    ).writeAsStringSync('Just text.\n');
    handDecision(root, '0002-other.md', title: 'Another two');
    for (final topic in [null, 'http', 'lib/a.dart']) {
      final reply = ask(topic);
      expect(reply.result['unreadable'], [
        {
          'file': '.appstein/decisions/0007-x.md',
          'problem': 'it has no front matter',
        },
      ], reason: '$topic');
      expect(reply.result['duplicates'], [
        {
          'number': '0002',
          'files': [
            '.appstein/decisions/0002-other.md',
            '.appstein/decisions/0002-routing.md',
          ],
        },
      ], reason: '$topic');
      expect(
        reply.summary,
        endsWith(
          ' 1 decision file is unreadable. Number 0002 is used by 2 files; '
          'rename one.',
        ),
        reason: '$topic',
      );
    }
  });

  test('a decisions folder that cannot be read is a refusal', () {
    final answer = decisionsInfo(
      const DecisionSet(folderProblem: 'Access is denied'),
    );
    expect(
      (answer as ToolRefusal).message,
      '`.appstein/decisions/` could not be read (Access is denied).',
    );
  });
}
