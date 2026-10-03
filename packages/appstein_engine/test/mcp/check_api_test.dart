import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';
import 'support/sample_delta.dart';

void main() {
  ToolReply ask(String name, [DeltaKnowledge delta = sampleDelta]) =>
      checkApi(name, delta) as ToolReply;

  List<Map<String, Object?>> matches(ToolReply reply) =>
      (reply.result['matches']! as List).cast<Map<String, Object?>>();

  test('a deprecated class: its message, migration and the note', () {
    final reply = ask('WillPopScope');
    expect(reply.result['status'], 'deprecated');
    final found = matches(reply);
    expect(found.first, {
      'kind': 'deprecated',
      'library': 'package:flutter',
      'name': 'WillPopScope',
      'deprecationKind': 'use',
      'message': 'Use PopScope instead.',
      'migrations': ["Migrate to 'PopScope'"],
    });
    expect(found.last['kind'], 'note');
    expect(found.last['id'], 'popscope-not-willpopscope');
    expect(
      reply.summary,
      '`WillPopScope` is deprecated: Use PopScope instead. 1 curated note '
      'mentions it.',
    );
    expectMatchesSchema(ToolSchemas.checkApiResult, withoutNulls(reply.result));
  });

  test('a member by its own name or with its class', () {
    expect(ask('withOpacity').result['status'], 'deprecated');
    expect(ask('Color.withOpacity').result['status'], 'deprecated');
    expect(ask('withOpacity()').result['status'], 'deprecated');
    expect(ask('colour').result['status'], 'deprecated');
  });

  test('a removed member, and a removed parameter of the same name', () {
    final reply = ask('overflow');
    expect(reply.result['status'], 'removed');
    final found = matches(reply);
    expect(found.map((m) => m['name']), [
      'Stack.new(overflow)',
      'Stack.overflow',
    ]);
    expect(found.first['parameter'], isTrue);
    expect(
      reply.summary,
      startsWith("`overflow` is removed: Migrate to 'clipBehavior'."),
    );
  });

  test('a constructor whose parameter is deprecated is itself ok', () {
    final reply = ask('Text.new');
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['parameter'], isTrue);
    expect(
      reply.summary,
      contains(
        'Some of its parameters are deprecated or '
        'removed; see `matches`.',
      ),
    );
    expect(ask('Text.new(textScaleFactor)').result['status'], 'deprecated');
  });

  test('a deprecation of another kind forbids only that use', () {
    final reply = ask('RegExp');
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['rule'], "don't implement it.");
    expect(
      reply.summary,
      contains("Its deprecation forbids only this: don't implement it."),
    );
  });

  test('changed and moved APIs are listed without changing the status', () {
    expect(ask('toggleableActiveColor').result['status'], 'ok');
    expect(matches(ask('toggleableActiveColor')).single['kind'], 'changed');
    final moved = ask('package:flutter/material.dart');
    expect(moved.result['status'], 'ok');
    expect(matches(moved).single['to'], 'package:material_ui/material_ui.dart');
  });

  test('a name nothing lists is ok, and says what that means', () {
    final reply = ask('Container');
    expect(reply.result['status'], 'ok');
    expect(matches(reply), isEmpty);
    expect(
      reply.result['meaning'],
      "Nothing the project imports deprecates or removes `Container`. "
      "Whether it exists isn't checked here; the Dart MCP server's analyzer "
      'does that.',
    );
    expect(
      reply.summary,
      '`Container` is ok: nothing the project imports deprecates or removes '
      'it.',
    );
  });

  test('without API lists, only the notes are checked, and it says so', () {
    final reply = ask('WillPopScope', sampleDeltaWithoutApis);
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['kind'], 'note');
    expect(
      reply.result['incomplete'],
      'Only the curated notes were checked: the API lists are missing (the '
      'packages could not be fetched).',
    );
    expect(reply.summary, startsWith('Only the curated notes were checked'));
  });

  test('an empty name is refused', () {
    expect(
      (checkApi('  ', sampleDelta) as ToolRefusal).message,
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  });
}
