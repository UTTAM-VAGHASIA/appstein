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
      startsWith(
        "`overflow` is removed in `Stack.new(overflow)` (package:flutter): "
        "Migrate to 'clipBehavior'.",
      ),
    );
  });

  test('a setter written with its class, and expression forms', () {
    for (final form in ['NewBox.colour', 'NewBox.colour=', 'colour']) {
      expect(ask(form).result['status'], 'deprecated', reason: form);
    }
    for (final form in [
      'color.withOpacity',
      '.withOpacity',
      'withOpacity(0.5)',
      'color.withOpacity(0.5)',
      'withOpacity( )',
    ]) {
      expect(ask(form).result['status'], 'deprecated', reason: form);
    }
  });

  test('a member asked through another class names the entry it matched', () {
    final reply = ask('Sub.withOpacity');
    expect(reply.result['status'], 'deprecated');
    expect(matches(reply).first['name'], 'Color.withOpacity');
    expect(
      reply.summary,
      startsWith(
        '`Sub.withOpacity` is deprecated in `Color.withOpacity` '
        '(package:flutter): Use .withValues() to avoid precision loss.',
      ),
    );
  });

  test('constructor forms: Owner() is Owner.new, Owner(param) too', () {
    final delta = DeltaKnowledge(
      flutterVersion: '3.47.5',
      languageVersion: '3.12',
      baseline: '3.16',
      coverage: 'complete',
      newestNotes: '3.47',
      notes: const [],
      laterNotes: const [],
      apis: const DeltaApis(
        deprecated: [
          DeltaDeprecatedApi(
            library: 'package:flutter',
            name: 'Foo.new',
            kind: 'use',
            message: 'Use Bar.',
          ),
          DeltaDeprecatedApi(
            library: 'package:flutter',
            name: 'Text.new(textScaleFactor)',
            kind: 'use',
            message: 'Use textScaler instead.',
          ),
        ],
        migrated: [],
        moved: [],
        unread: [],
      ),
    );
    expect(ask('Foo()', delta).result['status'], 'deprecated');
    expect(ask('Foo.new', delta).result['status'], 'deprecated');
    expect(ask('Text(textScaleFactor)', delta).result['status'], 'deprecated');
    final owner = ask('Text()', delta);
    expect(owner.result['status'], 'ok');
    expect(matches(owner).single['parameter'], isTrue);
  });

  test('a bare parameter name says it is that parameter', () {
    final reply = ask('textScaleFactor');
    expect(reply.result['status'], 'deprecated');
    expect(matches(reply).single['parameter'], isTrue);
    expect(
      reply.summary,
      '`textScaleFactor` is deprecated in `Text.new(textScaleFactor)` '
      '(package:flutter): Use textScaler instead.',
    );
    expect(reply.summary, isNot(contains('Some of its parameters')));
    expect(reply.result.containsKey('meaning'), isFalse);
  });

  test('a library written as a file URI finds its moved entry', () {
    for (final form in [
      'package:flutter/material.dart',
      'flutter/material.dart',
    ]) {
      final reply = ask(form);
      expect(matches(reply).single['kind'], 'moved', reason: form);
    }
  });

  test('notes match the identifiers, not "new" or a URI scheme', () {
    const note = CuratedNote(
      id: 'noisy',
      since: '3.16',
      priority: 1,
      area: NoteArea.framework,
      summary: 'Noise.',
      use: 'Nothing.',
      avoid: 'dart:io in new projects, package:foo/bar.dart.',
      source: 'https://example.com',
    );
    final delta = DeltaKnowledge(
      flutterVersion: '3.47.5',
      languageVersion: '3.12',
      baseline: '3.16',
      coverage: 'complete',
      newestNotes: '3.47',
      notes: const [note],
      laterNotes: const [],
      apis: sampleDelta.apis,
    );
    expect(
      matches(ask('Text.new', delta)).where((m) => m['kind'] == 'note'),
      isEmpty,
    );
    expect(
      matches(
        ask('package:flutter/material.dart', delta),
      ).where((m) => m['kind'] == 'note'),
      isEmpty,
    );
    expect(ask('Text.new', delta).summary, isNot(contains('curated')));
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

  group('a member of a deprecated or removed class', () {
    // The delta lists only elements with their own `@Deprecated`, so the
    // members of these classes are not in it.
    final delta = DeltaKnowledge(
      flutterVersion: '3.47.5',
      languageVersion: '3.12',
      baseline: '3.16',
      coverage: 'complete',
      newestNotes: '3.47',
      notes: const [],
      laterNotes: const [],
      apis: DeltaApis(
        deprecated: [
          ...sampleDelta.apis!.deprecated,
          const DeltaDeprecatedApi(
            library: 'package:flutter',
            name: 'MaterialStateProperty',
            kind: 'use',
            message: 'Use WidgetStateProperty instead.',
          ),
        ],
        migrated: [
          ...sampleDelta.apis!.migrated,
          const DeltaMigratedApi(
            library: 'package:flutter',
            name: 'OldWidget',
            status: 'removed',
            title: "Migrate to 'NewWidget'",
          ),
        ],
        moved: const [],
        unread: const [],
      ),
    );

    test('a member, a call and a constructor are deprecated with it', () {
      for (final form in [
        'MaterialStateProperty.all',
        'MaterialStateProperty.all(Colors.red)',
        'MaterialStateProperty.all(red)',
        'WillPopScope.new',
      ]) {
        expect(ask(form, delta).result['status'], 'deprecated', reason: form);
      }
    });

    test('the summary names the class and its library', () {
      final reply = ask('MaterialStateProperty.all', delta);
      expect(matches(reply).first['name'], 'MaterialStateProperty');
      expect(
        reply.summary,
        '`MaterialStateProperty.all`: its class `MaterialStateProperty` is '
        'deprecated (package:flutter): Use WidgetStateProperty instead.',
      );
      expectMatchesSchema(
        ToolSchemas.checkApiResult,
        withoutNulls(reply.result),
      );
    });

    test('a member of a removed class is removed', () {
      final reply = ask('OldWidget.build', delta);
      expect(reply.result['status'], 'removed');
      expect(
        reply.summary,
        "`OldWidget.build`: its class `OldWidget` is removed "
        "(package:flutter): Migrate to 'NewWidget'.",
      );
    });

    test('a class whose deprecation is of another kind stays ok', () {
      expect(ask('RegExp.new', delta).result['status'], 'ok');
      expect(ask('RegExp.firstMatch', delta).result['status'], 'ok');
    });

    test('a member of a class nothing lists stays ok', () {
      expect(ask('Container.new', delta).result['status'], 'ok');
      expect(ask('Colors.red', delta).result['status'], 'ok');
    });

    test('a deprecated member beats a clean class, removed beats both', () {
      expect(ask('Color.withOpacity', delta).result['status'], 'deprecated');
      expect(ask('Stack.overflow', delta).result['status'], 'removed');
    });
  });

  test('type arguments are ignored, nested ones too', () {
    final delta = sampleDelta;
    for (final form in [
      'withOpacity<T>',
      'color.withOpacity<T>(0.5)',
      'WillPopScope<Foo>',
      'WillPopScope<Map<String, List<int>>>()',
    ]) {
      final reply = ask(form, delta);
      expect(reply.result['status'], 'deprecated', reason: form);
    }
    expect(ask('withOpacity<T>').result['name'], 'withOpacity');
  });

  test('type arguments on a deprecated class with a member', () {
    final delta = DeltaKnowledge(
      flutterVersion: '3.47.5',
      languageVersion: '3.12',
      baseline: '3.16',
      coverage: 'complete',
      newestNotes: '3.47',
      notes: const [],
      laterNotes: const [],
      apis: const DeltaApis(
        deprecated: [
          DeltaDeprecatedApi(
            library: 'package:flutter',
            name: 'MaterialStateProperty',
            kind: 'use',
            message: 'Use WidgetStateProperty instead.',
          ),
        ],
        migrated: [],
        moved: [],
        unread: [],
      ),
    );
    for (final form in [
      'MaterialStateProperty<Color>',
      'MaterialStateProperty<Color?>.all',
      'MaterialStateProperty<List<Color>>.all(Colors.red)',
    ]) {
      expect(ask(form, delta).result['status'], 'deprecated', reason: form);
    }
  });

  test('a named argument is the parameter of that name', () {
    final reply = ask('Text(textScaleFactor: 1.2)');
    expect(reply.result['status'], 'deprecated');
    expect(matches(reply).single['name'], 'Text.new(textScaleFactor)');
    expect(ask('Text.new(textScaleFactor:1.2)').result['status'], 'deprecated');
    expect(ask('Text(style: s)').result['status'], 'ok');
  });

  test('an empty name is refused', () {
    expect(
      (checkApi('  ', sampleDelta) as ToolRefusal).message,
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  });
}
