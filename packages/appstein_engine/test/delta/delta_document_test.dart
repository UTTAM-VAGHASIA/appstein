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
        name: 'Stack.new',
        status: MigrationStatus.changed,
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
  }) => DeltaInputs(
    flutterVersion: flutterVersion,
    languageVersion: languageVersion,
    baseline: '3.16',
    coverage: coverage,
    newestNotes: '3.47',
    notes: notes,
    facts: facts,
    skipped: skipped,
  );

  test('renders every section, matching the golden', () {
    expectTextGolden('delta.md', renderDelta(inputs()));
  });

  test('with no facts it says why, and lists only the notes', () {
    final text = renderDelta(
      inputs(facts: null, skipped: 'the packages could not be fetched'),
    );
    expect(
      text,
      contains(
        'Deprecated and removed APIs are missing: the packages could not be '
        'fetched. Fix that, then run `appstein sync` again.',
      ),
    );
    expect(text, contains('## Notes'));
    for (final missing in [
      '## Deprecated',
      '## Removed',
      '## Moved libraries',
      '## Not read',
    ]) {
      expect(text, isNot(contains(missing)));
    }
  });

  test('a skip reason ending in a full stop is not doubled', () {
    final text = renderDelta(
      inputs(facts: null, skipped: 'pubspec.lock is not valid YAML.'),
    );
    expect(text, contains('missing: pubspec.lock is not valid YAML. Fix'));
  });

  test('empty facts say None, and leave out the optional sections', () {
    final text = renderDelta(inputs(facts: const DeltaFacts()));
    expect(text, contains('## Deprecated\n\nAPIs'));
    expect(text, contains('`dart analyze` reports each use.\n\nNone.\n'));
    expect(text, contains('`dart fix` applies each migration.\n\nNone.\n'));
    expect(text, isNot(contains('## Moved libraries')));
    expect(text, isNot(contains('## Not read')));
  });

  test(
    'a message without a final full stop gets one before the migrations',
    () {
      final text = renderDelta(
        inputs(
          facts: const DeltaFacts(
            deprecated: [
              DeprecatedApi(
                group: 'dart:core',
                name: 'IntegerDivisionByZeroException',
                kind: DeprecationKind.use,
                message: 'Use UnsupportedError instead',
                migrations: ["Replace with 'UnsupportedError'"],
              ),
            ],
          ),
        ),
      );
      expect(
        text,
        contains(
          '- `IntegerDivisionByZeroException`: Use UnsupportedError instead. '
          "`dart fix` migrates it: Replace with 'UnsupportedError'.\n",
        ),
      );
    },
  );

  test('a message with no migrations is quoted as it is', () {
    final text = renderDelta(
      inputs(
        facts: const DeltaFacts(
          deprecated: [
            DeprecatedApi(
              group: 'dart:core',
              name: 'Thing',
              kind: DeprecationKind.use,
              message: 'Use Other instead',
            ),
          ],
        ),
      ),
    );
    expect(text, contains('- `Thing`: Use Other instead\n'));
  });

  test('titles and reasons that span lines become one line each', () {
    final text = renderDelta(
      inputs(
        facts: const DeltaFacts(
          migrated: [
            MigratedApi(
              group: 'package:kit',
              name: 'Gone',
              status: MigrationStatus.removed,
              title: 'Rename to\r\n  New',
            ),
          ],
          unread: [
            UnreadMigrations(
              file: 'package:kit/fix_data.yaml',
              reason: 'line 1: is not valid YAML:\nunexpected',
            ),
          ],
        ),
      ),
    );
    expect(text, contains('- `Gone`: removed. Rename to New.\n'));
    expect(
      text,
      contains(
        '- `package:kit/fix_data.yaml`: line 1: is not valid YAML: '
        'unexpected\n',
      ),
    );
    expect(
      renderDelta(inputs(facts: null, skipped: 'no\npackages')),
      contains('no packages.'),
    );
  });

  test('no notes says None', () {
    expect(
      renderDelta(inputs(notes: const [])),
      contains('most important first (priority 1 to 3).\n\nNone.\n'),
    );
  });

  test('partial coverage adds the notes-may-be-incomplete line', () {
    expect(
      renderDelta(
        inputs(flutterVersion: '3.50.1', coverage: NotesCoverage.partial),
      ),
      contains(
        'Curated notes may be incomplete for Flutter 3.50: the newest notes '
        'are for 3.47.',
      ),
    );
  });

  test('an unknown language version keeps every note in Notes, each marked '
      'with its language', () {
    final text = renderDelta(inputs(languageVersion: null));
    expect(
      text,
      startsWith('# Version delta: Flutter 3.47.5, Dart language unknown\n'),
    );
    expect(text, isNot(contains('## Needs a newer language version')));
    expect(text, contains('(priority 2, since 3.47, language 3.13)'));
  });

  group('deltaNotes', () {
    final notes = CuratedNotes.bundled();

    test('the default baseline keeps the 3.16 notes', () {
      expect(
        deltaNotes(
          notes,
          flutterVersion: '3.47.5',
          baseline: '3.16',
        ).map((n) => n.id),
        contains('popscope-not-willpopscope'),
      );
    });

    test('a later baseline drops the older notes', () {
      final ids = deltaNotes(
        notes,
        flutterVersion: '3.47.5',
        baseline: '3.24',
      ).map((n) => n.id);
      expect(ids, isNot(contains('popscope-not-willpopscope')));
      expect(ids, contains('material-ui-packages'));
    });

    test('notes newer than the SDK are left out', () {
      expect(
        deltaNotes(
          notes,
          flutterVersion: '3.44.9',
          baseline: '3.16',
        ).map((n) => n.id),
        isNot(contains('material-ui-packages')),
      );
    });

    test('an unknown Flutter version gets no notes', () {
      expect(
        deltaNotes(notes, flutterVersion: '0.0.0-unknown', baseline: '3.16'),
        isEmpty,
      );
    });
  });
}
