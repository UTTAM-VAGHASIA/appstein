import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const sdk = SdkInfo(
    flutterVersion: '3.47.5',
    dartVersion: '3.13.4',
    channel: 'stable',
    languageVersion: '3.12',
    notesCoverage: NotesCoverage.complete,
  );
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
  const headings = [
    '## Project',
    '## Rules',
    '## Features',
    '## Where things live',
    '## Version notes',
    '## Decisions',
    '## Current work',
    '## Freshness',
  ];

  IndexInputs small({
    List<IndexFeature> features = const [
      IndexFeature(
        name: 'booking',
        folder: 'lib/ui/booking',
        screens: 1,
        mainFiles: [
          'widgets/booking_screen.dart',
          'view_models/booking_viewmodel.dart',
        ],
      ),
      IndexFeature(
        name: 'profile',
        folder: 'lib/ui/profile',
        screens: 1,
        mainFiles: ['widgets/profile_screen.dart'],
      ),
    ],
    List<IndexDecision> decisions = const [
      IndexDecision(
        file: '0002-state.md',
        id: '0002',
        title: 'State management with provider + ChangeNotifier',
        status: 'accepted',
      ),
    ],
    List<String> currentWork = const [
      '# Add booking export',
      '',
      'Status: tests written.',
    ],
    Set<String> tools = indexTools,
  }) => IndexInputs(
    tools: tools,
    projectName: 'fixture_app',
    sdk: sdk,
    appsteinVersion: '0.1.0-dev',
    newestNotes: '3.47',
    stackPack: 'official_mvvm',
    platforms: const ['android', 'ios'],
    appIds: const [
      'Android applicationId: `dev.sample.probe_app`',
      'iOS bundle id: `dev.sample.probeApp`',
    ],
    features: features,
    layers: const {
      'ui': ['lib/ui/**'],
      'domain': ['lib/domain/**'],
    },
    notes: const [popScope],
    apiCounts: const DeltaCounts(
      deprecated: 4,
      removed: 3,
      changed: 0,
      moved: 1,
    ),
    decisions: decisions,
    currentWork: currentWork,
  );

  final bundledNotes = CuratedNotes.bundled().notesFor('3.47.5');

  IndexInputs large() => IndexInputs(
    projectName: 'a_very_large_app',
    sdk: sdk,
    appsteinVersion: '0.1.0-dev',
    newestNotes: '3.47',
    stackPack: 'official_mvvm',
    platforms: platformFolderNames,
    appIds: [
      'Android applicationId: `com.example.a_very_large_app` (12 flavors may '
          'change it; see `map/native.json`)',
      'iOS bundle id: '
          '${[for (var i = 0; i < 9; i++) 'Config$i `com.example.app.flavor$i`'].join(', ')}',
    ],
    features: [
      for (var i = 0; i < 300; i++)
        IndexFeature(
          name: 'feature_$i',
          folder: 'lib/ui/feature_$i',
          screens: 300 - i,
          mainFiles: [
            'widgets/screen_$i.dart',
            'view_models/view_model_$i.dart',
            'widgets/panel_$i.dart',
          ],
        ),
    ],
    layers: const OfficialMvvmPack().layerRules.layers,
    notes: bundledNotes,
    apiCounts: const DeltaCounts(
      deprecated: 512,
      removed: 300,
      changed: 40,
      moved: 2,
    ),
    decisions: [
      for (var i = 1; i <= 100; i++)
        IndexDecision(
          file: '${'$i'.padLeft(4, '0')}-decision.md',
          id: '$i'.padLeft(4, '0'),
          title: 'Decision $i about one part of the app, with a long title',
          status: 'accepted',
        ),
    ],
    currentWork: [
      for (var i = 1; i <= 200; i++)
        'Line $i of the current task, long enough to matter.',
    ],
  );

  int bytes(String text) => utf8.encode(text).length;

  test('a small project renders every section in full, the same way each '
      'time', () {
    final text = renderIndex(small(), byteBudget: indexByteBudget);
    expect(
      text,
      [
        '# fixture_app',
        '',
        "Appstein's summary of this project, always in view. `appstein "
            "sync` writes it; don't edit it. Everything else is in "
            "`.appstein/` and Appstein's MCP tools.",
        '',
        '## Project',
        '',
        '- Flutter 3.47.5 (stable channel), Dart 3.13.4, language version '
            '3.12',
        '- Stack pack: `official_mvvm`',
        '- Platforms: android, ios',
        '- Android applicationId: `dev.sample.probe_app`',
        '- iOS bundle id: `dev.sample.probeApp`',
        '',
        '## Rules',
        '',
        "- Ask Appstein's MCP tools (`where_is()`, `feature()`, `route()`) "
            'before searching the code.',
        '- Run `verify()` before you say a task is done.',
        '- Never upgrade native toolchain versions (Gradle, the Android '
            'Gradle Plugin, Kotlin, the NDK, SDK levels, the iOS deployment '
            'target) yourself; ask `toolchain()`.',
        '- Dependencies: pure Dart for small helpers; a package that passes '
            '`package_check()` for platform features; Pigeon with platform '
            'channels for small native code.',
        '',
        '## Features',
        '',
        '| Feature | Screens | Main files |',
        '|---|---|---|',
        '| `booking` | 1 | `lib/ui/booking/`: widgets/booking_screen.dart, '
            'view_models/booking_viewmodel.dart |',
        '| `profile` | 1 | `lib/ui/profile/`: widgets/profile_screen.dart |',
        '',
        '## Where things live',
        '',
        '- `ui`: `lib/ui/**`',
        '- `domain`: `lib/domain/**`',
        '',
        '## Version notes',
        '',
        '- **popscope-not-willpopscope** (priority 1): PopScope replaces '
            'WillPopScope.',
        '',
        '`platform/delta.md` also lists 4 deprecated APIs, 3 removed APIs, '
            '0 changed APIs and 1 moved library; ask `what_changed()`.',
        '',
        '## Decisions',
        '',
        '- 0002 State management with provider + ChangeNotifier (accepted): '
            '[0002-state.md](<decisions/0002-state.md>)',
        '',
        '## Current work',
        '',
        '> # Add booking export',
        '>',
        '> Status: tests written.',
        '',
        '## Freshness',
        '',
        'Synced by Appstein 0.1.0-dev for Flutter 3.47.5. Curated notes cover '
            'Flutter 3.47 and earlier.',
        '',
      ].join('\n'),
    );
    expect(renderIndex(small(), byteBudget: indexByteBudget), text);
  });

  test('a tool the server does not offer is never named: its rule goes, '
      'and a pointer names the file', () {
    final offered = mcpToolNames.toSet();
    final inputs = small(
      tools: offered,
      currentWork: [for (var i = 1; i <= 10; i++) 'Step $i of the task.'],
      decisions: [
        for (var i = 1; i <= 3; i++)
          IndexDecision(
            file: '000$i-d.md',
            id: '000$i',
            title: 'Decision $i',
            status: 'accepted',
          ),
      ],
    );
    final full = renderIndex(inputs, byteBudget: indexByteBudget);
    // Cut until every line of current work and one decision are hidden.
    var cut = full;
    for (var budget = bytes(full) - 1; budget > 0; budget--) {
      cut = renderIndex(inputs, byteBudget: budget);
      if (cut.contains('older decision')) break;
    }
    for (final text in [full, cut]) {
      for (final tool in indexTools.difference(offered)) {
        expect(text, isNot(contains('`$tool()`')), reason: tool);
      }
    }
    expect(full, isNot(contains('before you say a task is done')));
    expect(
      full,
      contains(
        '- Dependencies: pure Dart for small helpers; a well-maintained '
        'package for platform features; Pigeon with platform channels for '
        'small native code.',
      ),
    );
    expect(cut, contains('…and 10 more lines in `memory/current.md`.'));
    expect(cut, contains('…and 1 older decision in `decisions/`.'));
    // The tools it does offer are still named.
    expect(full, contains('ask `toolchain()`'));
    expect(full, contains('ask `what_changed()`'));
  });

  test('what is unknown or missing is said plainly', () {
    final text = renderIndex(
      const IndexInputs(
        projectName: null,
        sdk: SdkInfo(
          flutterVersion: '3.48.0',
          dartVersion: '3.14.0',
          channel: 'beta',
          notesCoverage: NotesCoverage.partial,
        ),
        appsteinVersion: '0.1.0-dev',
        newestNotes: '3.47',
        stackPack: null,
        platforms: [],
        appIds: [],
        features: null,
        featuresMissing:
            'the project map was skipped: the packages could not be fetched',
        layers: null,
        notes: [],
        apiCounts: null,
        decisionsError: 'Access is denied.',
        currentWorkError: 'Access is denied.',
      ),
      byteBudget: indexByteBudget,
    );
    for (final line in [
      '# This project',
      '- Flutter 3.48.0 (beta channel), Dart 3.14.0, language version '
          'unknown',
      '- Stack pack: none',
      '- Platforms: none found',
      'Not available: the project map was skipped: the packages could not '
          'be fetched.',
      'No stack pack, so no layers.',
      'No curated notes for this SDK.',
      '`platform/delta.md` has no API lists this time; it says why. Ask '
          '`what_changed()`.',
      "Couldn't read `.appstein/decisions/`: Access is denied.",
      "Couldn't read `memory/current.md`: Access is denied.",
      'Synced by Appstein 0.1.0-dev for Flutter 3.48.0. Curated notes may be '
          'incomplete for Flutter 3.48: the newest notes are for 3.47.',
    ]) {
      expect(text, contains(line));
    }
  });

  test('table cells escape |, a feature shows at most two main files, an '
      'unreadable decision says why, and no features says so', () {
    final text = renderIndex(
      small(
        features: const [
          IndexFeature(
            name: 'odd|name',
            folder: 'lib/ui/odd|name',
            screens: 3,
            mainFiles: ['a.dart', 'b.dart', 'c.dart'],
          ),
        ],
        decisions: const [
          IndexDecision.unreadable(
            file: '0007 bad.md',
            id: '0007',
            problem: 'it has no front matter',
          ),
        ],
      ),
      byteBudget: indexByteBudget,
    );
    expect(
      text,
      contains(r'| `odd\|name` | 3 | `lib/ui/odd\|name/`: a.dart, b.dart, … |'),
    );
    expect(
      text,
      contains(
        '- [0007 bad.md](<decisions/0007 bad.md>): unreadable (it has no '
        'front matter).',
      ),
    );
    expect(
      renderIndex(small(features: const []), byteBudget: indexByteBudget),
      contains('## Features\n\nNone found.\n'),
    );
  });

  test('over budget with at most 5 notes, current work is the first thing '
      'cut', () {
    // small() has 1 note, already at the floor of 5, so no note can go.
    final inputs = small(
      currentWork: [for (var i = 1; i <= 10; i++) 'Step $i of the task.'],
    );
    final full = renderIndex(inputs, byteBudget: indexByteBudget);
    final cut = renderIndex(inputs, byteBudget: bytes(full) - 1);
    expect(bytes(cut), lessThan(bytes(full)));
    expect(cut, contains('; ask `memory_read()`.'));
    expect(cut, contains('- 0002 State management'));
    expect(cut, contains('| `profile` |'));
  });

  test('over budget with more than 5 notes, a note is cut before any current '
      'work', () {
    final inputs = IndexInputs(
      projectName: 'fixture_app',
      sdk: sdk,
      appsteinVersion: '0.1.0-dev',
      newestNotes: '3.47',
      stackPack: null,
      platforms: const ['android'],
      appIds: const [],
      features: const [],
      layers: null,
      notes: bundledNotes.take(8).toList(),
      apiCounts: null,
      currentWork: [for (var i = 1; i <= 10; i++) 'Step $i of the task.'],
    );
    final full = renderIndex(inputs, byteBudget: 1000000);
    final cut = renderIndex(inputs, byteBudget: bytes(full) - 1);
    expect(cut, contains('…and 1 more note; ask `what_changed()`.'));
    expect(cut, isNot(contains('ask `memory_read()`')));
    for (var i = 1; i <= 10; i++) {
      expect(cut, contains('> Step $i of the task.'));
    }
  });

  test('a very large project fits; notes go to 5, then current work and '
      'decisions go, and features keep at least 5', () {
    const budget = indexByteBudget - 300;
    final text = renderIndex(large(), byteBudget: budget);
    expect(bytes(text), lessThanOrEqualTo(budget));
    expect(text, contains('…and 200 more lines; ask `memory_read()`.'));
    expect(text, contains('…and 100 older decisions; ask `decisions()`.'));
    final lines = text.split('\n');
    final rows = [
      for (final line in lines)
        if (line.startsWith('| `feature_')) line,
    ];
    // Notes, current work and decisions were all cut, so features give up
    // rows too, but stay above their floor of 5 at this budget.
    expect(rows.length, 12);
    expect(
      rows.first,
      '| `feature_0` | 300 | `lib/ui/feature_0/`: widgets/screen_0.dart, '
      'view_models/view_model_0.dart, … |',
    );
    expect(text, contains('; ask `feature()`.'));
    final notes = lines.where((line) => line.startsWith('- **')).length;
    expect(notes, 5);
    expect(
      text,
      contains(
        '…and ${bundledNotes.length - notes} more notes; ask `what_changed()`.',
      ),
    );
    for (final heading in headings) {
      expect(text, contains(heading));
    }
  });

  test('the cut order holds at every step: notes down to 5, current work, '
      'decisions, features down to 5, then features, then notes', () {
    // Each step asks for one byte less than the last text, which forces
    // exactly the next cut.
    ({int work, int decisions, int rows, int notes}) shown(String text) {
      final lines = text.split('\n');
      int count(bool Function(String) test) => lines.where(test).length;
      return (
        work: count((l) => l.startsWith('> Line ')),
        decisions: count((l) => l.startsWith('- 0')),
        rows: count((l) => l.startsWith('| `feature_')),
        notes: count((l) => l.startsWith('- **')),
      );
    }

    var text = renderIndex(large(), byteBudget: 1000000);
    final states = [shown(text)];
    expect(states.first.work, 10);
    expect(states.first.decisions, 100);
    expect(states.first.rows, 15);
    expect(states.first.notes, 10);
    while (true) {
      final next = renderIndex(large(), byteBudget: bytes(text) - 1);
      if (next == text) break;
      text = next;
      states.add(shown(text));
    }
    expect(states.last.rows, 0);
    expect(states.last.notes, 0);
    for (final s in states) {
      // Current work is only cut once notes are down to 5.
      if (s.work < 10) expect(s.notes, lessThanOrEqualTo(5), reason: '$s');
      // Decisions are only cut once current work is gone.
      if (s.decisions < 100) expect(s.work, 0, reason: '$s');
      // Features are only cut once decisions are gone.
      if (s.rows < 15) expect(s.decisions, 0, reason: '$s');
      // Notes never go below 5 while any feature row is left: in the last
      // resort features reach 0 first.
      if (s.notes < 5) expect(s.rows, 0, reason: '$s');
      // Notes, decisions and current work are untouched until their turn.
      if (s.notes > 5) {
        expect(s.work, 10, reason: '$s');
        expect(s.decisions, 100, reason: '$s');
        expect(s.rows, 15, reason: '$s');
      }
      if (s.work > 0) {
        expect(s.decisions, 100, reason: '$s');
        expect(s.rows, 15, reason: '$s');
      }
      if (s.decisions > 0) expect(s.rows, 15, reason: '$s');
      // Notes only fall below 5 once features are at 0 (checked above), so
      // while any feature row is left they are at least 5.
      if (s.rows > 0) expect(s.notes, greaterThanOrEqualTo(5), reason: '$s');
    }
    // Each phase really happens.
    bool phase(
      bool Function(({int work, int decisions, int rows, int notes})) f,
    ) => states.any(f);
    // 1. notes 10 -> 5 with everything else full.
    expect(phase((s) => s.notes < 10 && s.notes > 5 && s.work == 10), isTrue);
    // 2. current work 10 -> 0, notes at 5, decisions full.
    expect(
      phase(
        (s) => s.work < 10 && s.work > 0 && s.notes == 5 && s.decisions == 100,
      ),
      isTrue,
    );
    // 3. decisions 100 -> 0, features still 15.
    expect(
      phase((s) => s.decisions < 100 && s.decisions > 0 && s.rows == 15),
      isTrue,
    );
    // 4. features 15 -> 5, notes at 5.
    expect(
      phase(
        (s) => s.rows < 15 && s.rows > 5 && s.decisions == 0 && s.notes == 5,
      ),
      isTrue,
    );
    // 5. last resort: features 5 -> 0 with notes at 5, then notes 5 -> 0.
    expect(phase((s) => s.rows < 5 && s.rows > 0 && s.notes == 5), isTrue);
    expect(phase((s) => s.rows == 0 && s.notes == 5), isTrue);
    expect(phase((s) => s.rows == 0 && s.notes < 5 && s.notes > 0), isTrue);
  });

  test('when decisions are cut, the newest stay and the pointer counts the '
      'older ones', () {
    final decisions = [
      for (var i = 1; i <= 5; i++)
        IndexDecision(
          file: '000$i-decision.md',
          id: '000$i',
          title: 'Decision $i',
          status: 'accepted',
        ),
    ];
    final inputs = small(decisions: decisions, currentWork: const []);
    final full = renderIndex(inputs, byteBudget: indexByteBudget);
    expect(full, isNot(contains('older decision')));

    final one = renderIndex(inputs, byteBudget: bytes(full) - 1);
    expect(one, isNot(contains('- 0001 Decision 1')));
    for (final i in [2, 3, 4, 5]) {
      expect(one, contains('- 000$i Decision $i (accepted)'));
    }
    expect(one, contains('…and 1 older decision; ask `decisions()`.'));

    final two = renderIndex(inputs, byteBudget: bytes(one) - 1);
    expect(two, isNot(contains('- 0001 Decision 1')));
    expect(two, isNot(contains('- 0002 Decision 2')));
    for (final i in [3, 4, 5]) {
      expect(two, contains('- 000$i Decision $i (accepted)'));
    }
    expect(two, contains('…and 2 older decisions; ask `decisions()`.'));
  });

  test('when even the floors do not fit, features and notes go too, and '
      'every section still renders', () {
    final text = renderIndex(large(), byteBudget: 1000);
    expect(text, isNot(contains('| `feature_')));
    expect(text, isNot(contains('- **')));
    expect(text, contains('…and 300 more; ask `feature()`.'));
    expect(
      text,
      contains('…and ${bundledNotes.length} more notes; ask `what_changed()`.'),
    );
    for (final heading in headings) {
      expect(text, contains(heading));
    }
  });

  test('indexBodyBudget leaves room for the front matter: a body of exactly '
      'that many bytes makes a 4,500-byte file', () {
    final meta = KnowledgeMeta(
      generatedAt: '2026-10-01T09:00:00Z',
      appsteinVersion: '0.1.0-dev',
      formatVersion: knowledgeFormatVersion,
      sdkVersion: '3.47.5',
      inputHash: 'a' * 64,
    );
    final budget = indexBodyBudget(meta);
    final body = '${'x' * (budget - 1)}\n';
    expect(
      utf8.encode(markdownWithFrontMatter(body, meta)).length,
      indexByteBudget,
    );
  });
}
