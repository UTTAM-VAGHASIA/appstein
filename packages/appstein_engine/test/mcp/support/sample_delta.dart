import 'package:appstein_protocol/appstein_protocol.dart';

const _popScope = CuratedNote(
  id: 'popscope-not-willpopscope',
  since: '3.16',
  priority: 1,
  area: NoteArea.framework,
  summary: 'PopScope replaces WillPopScope.',
  use: '`PopScope` with `canPop`.',
  avoid: '`WillPopScope`.',
  source:
      'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
);

const _dotShorthands = CuratedNote(
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

const _primaryConstructors = CuratedNote(
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

/// A delta like a small app's: deprecations of each kind, removed and
/// changed APIs, a moved library and an unread migration file.
const sampleDelta = DeltaKnowledge(
  flutterVersion: '3.47.5',
  languageVersion: '3.12',
  baseline: '3.16',
  coverage: 'complete',
  newestNotes: '3.47',
  notes: [_popScope, _dotShorthands],
  laterNotes: [_primaryConstructors],
  apis: DeltaApis(
    deprecated: [
      DeltaDeprecatedApi(
        library: 'dart:core',
        name: 'RegExp',
        kind: 'implement',
        rule: "don't implement it.",
        message: "This class will become 'final' in a future release.",
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'Color.withOpacity',
        kind: 'use',
        message: 'Use .withValues() to avoid precision loss.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'NewBox.colour=',
        kind: 'use',
        message: 'Use color.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'Text.new(textScaleFactor)',
        kind: 'use',
        message: 'Use textScaler instead.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'WillPopScope',
        kind: 'use',
        message: 'Use PopScope instead.',
        migrations: ["Migrate to 'PopScope'"],
      ),
      DeltaDeprecatedApi(
        library: 'package:go_router',
        name: 'GoRouter.new(label)',
        kind: 'optional',
        rule: 'always pass this argument: it will become required.',
      ),
    ],
    migrated: [
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'Stack.new(overflow)',
        status: 'removed',
        title: "Migrate to 'clipBehavior'",
      ),
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'Stack.overflow',
        status: 'removed',
        title: "Migrate to 'clipBehavior'",
      ),
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'ThemeData.toggleableActiveColor',
        status: 'changed',
        title: 'Move to colorScheme.secondary',
      ),
      DeltaMigratedApi(
        library: 'package:go_router',
        name: 'GoRouterState.location',
        status: 'removed',
        title: "Replaces 'location' with `uri.toString()`",
      ),
    ],
    moved: [
      DeltaMovedLibrary(
        from: 'package:flutter/material.dart',
        to: 'package:material_ui/material_ui.dart',
        title: 'Migrate from flutter/material.dart to material_ui.',
      ),
    ],
    unread: [
      DeltaUnreadFile(
        file: 'package:delta_kit/fix_data/fix_broken.yaml',
        reason: 'line 2: A transform needs an "element" map.',
      ),
    ],
  ),
);

/// [sampleDelta] without its API lists, as after a skipped map.
const sampleDeltaWithoutApis = DeltaKnowledge(
  flutterVersion: '3.47.5',
  languageVersion: '3.12',
  baseline: '3.16',
  coverage: 'complete',
  newestNotes: '3.47',
  notes: [_popScope, _dotShorthands],
  laterNotes: [_primaryConstructors],
  missing: 'the packages could not be fetched',
);
