import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  const popScope = CuratedNote(
    id: 'popscope-not-willpopscope',
    since: '3.16',
    priority: 1,
    area: NoteArea.framework,
    summary: 'PopScope replaces WillPopScope.',
    use: '`PopScope` with `canPop` and `onPopInvokedWithResult`.',
    avoid: '`WillPopScope`.',
    source:
        'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
  );
  const dotShorthands = CuratedNote(
    id: 'dot-shorthands',
    since: '3.38',
    languageVersion: '3.10',
    priority: 2,
    area: NoteArea.dart,
    summary: 'Dot shorthands omit the type name.',
    use: '`mainAxisAlignment: .center`.',
    avoid: 'Shorthands below language version 3.10.',
    source: 'https://dart.dev/language/dot-shorthands',
  );
  const primaryConstructors = CuratedNote(
    id: 'dart-primary-constructors',
    since: '3.47',
    languageVersion: '3.13',
    priority: 2,
    area: NoteArea.dart,
    summary: 'Primary constructors declare fields in the class header.',
    use: '`class Point(final int x, final int y);`.',
    avoid: 'Primary constructors below language version 3.13.',
    source: 'https://dart.dev/language/constructors',
  );
  const facts = DeltaFacts(
    deprecated: [
      DeprecatedApi(
        group: 'dart:core',
        name: 'RegExp',
        kind: DeprecationKind.implement,
        message:
            "This class will become 'final' in a future release. 'Pattern' "
            'may be a more appropriate interface to implement.',
      ),
      DeprecatedApi(
        group: 'package:flutter',
        name: 'Text.new(textScaleFactor)',
        kind: DeprecationKind.use,
      ),
      DeprecatedApi(
        group: 'package:flutter',
        name: 'WillPopScope',
        kind: DeprecationKind.use,
        message:
            'Use PopScope instead. This feature was deprecated after '
            'v3.12.0-1.0.pre.',
        migrations: ["Migrate to 'PopScope'"],
      ),
      DeprecatedApi(
        group: 'package:go_router',
        name: 'GoRouter.new(label)',
        kind: DeprecationKind.optional,
      ),
    ],
    migrated: [
      MigratedApi(
        group: 'package:flutter',
        name: 'Stack.new(overflow)',
        status: MigrationStatus.removed,
        title: "Migrate to 'clipBehavior'",
      ),
      MigratedApi(
        group: 'package:flutter',
        name: 'Stack.overflow',
        status: MigrationStatus.removed,
        title: "Migrate to 'clipBehavior'",
      ),
      MigratedApi(
        group: 'package:go_router',
        name: 'GoRouterState.location',
        status: MigrationStatus.removed,
        title: "Replaces 'location' in 'GoRouterState' with `uri.toString()`",
      ),
    ],
    moved: [
      MovedLibrary(
        from: 'package:flutter/material.dart',
        to: 'package:material_ui/material_ui.dart',
        title:
            'Migrate from flutter/material.dart to material_ui/material_ui.dart.',
      ),
    ],
    unread: [
      UnreadMigrations(
        file: 'package:delta_kit/fix_data/fix_broken.yaml',
        reason: 'line 2: A transform needs an "element" map or a "library".',
      ),
    ],
  );

  DeltaInputs inputs({
    String flutterVersion = '3.47.5',
    String? languageVersion = '3.12',
    NotesCoverage coverage = NotesCoverage.complete,
    List<CuratedNote> notes = const [
      popScope,
      dotShorthands,
      primaryConstructors,
    ],
    DeltaFacts? facts = facts,
    String? skipped,
    String? internalError,
  }) => DeltaInputs(
    flutterVersion: flutterVersion,
    languageVersion: languageVersion,
    baseline: '3.16',
    coverage: coverage,
    newestNotes: '3.47',
    notes: notes,
    facts: facts,
    skipped: skipped,
    internalError: internalError,
  );

  test('holds the same notes and facts as delta.md, matching the golden', () {
    expectGolden('delta.json', deltaJsonBody(inputs()));
  });

  test('splits the notes the project can use from those that need a newer '
      'language version', () {
    final body = DeltaKnowledge.fromJson(deltaJsonBody(inputs()));
    expect(
      [for (final n in body.notes) n.id],
      ['popscope-not-willpopscope', 'dot-shorthands'],
    );
    expect(
      [for (final n in body.laterNotes) n.id],
      ['dart-primary-constructors'],
    );
  });

  test('names the library, kind and rule of each deprecation', () {
    final apis = DeltaKnowledge.fromJson(deltaJsonBody(inputs())).apis!;
    final regExp = apis.deprecated.first;
    expect(regExp.library, 'dart:core');
    expect(regExp.kind, 'implement');
    expect(regExp.rule, "don't implement it.");
    expect(apis.migrated.map((m) => m.status), everyElement('removed'));
    expect(apis.moved.single.to, 'package:material_ui/material_ui.dart');
  });

  test('without facts, the API lists are missing with the skip reason', () {
    final body = DeltaKnowledge.fromJson(
      deltaJsonBody(
        inputs(facts: null, skipped: 'the packages could not be fetched'),
      ),
    );
    expect(body.apis, isNull);
    expect(body.missing, 'the packages could not be fetched');
  });

  test('an internal error names only its type', () {
    final body = DeltaKnowledge.fromJson(
      deltaJsonBody(inputs(facts: null, internalError: 'StateError')),
    );
    expect(
      body.missing,
      'Appstein could not collect them because of an internal error '
      '(StateError)',
    );
  });
}
