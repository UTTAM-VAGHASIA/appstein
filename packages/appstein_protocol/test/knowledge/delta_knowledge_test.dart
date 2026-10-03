import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const note = CuratedNote(
    id: 'popscope-not-willpopscope',
    since: '3.16',
    priority: 1,
    area: NoteArea.framework,
    summary: 'PopScope replaces WillPopScope.',
    use: '`PopScope`.',
    avoid: '`WillPopScope`.',
    source:
        'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
  );
  const knowledge = DeltaKnowledge(
    flutterVersion: '3.47.5',
    languageVersion: '3.12',
    baseline: '3.16',
    coverage: 'complete',
    newestNotes: '3.47',
    notes: [note],
    laterNotes: [],
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
          name: 'WillPopScope',
          kind: 'use',
          message: 'Use PopScope instead.',
          migrations: ["Migrate to 'PopScope'"],
        ),
      ],
      migrated: [
        DeltaMigratedApi(
          library: 'package:flutter',
          name: 'Stack.overflow',
          status: 'removed',
          title: "Migrate to 'clipBehavior'",
        ),
      ],
      moved: [
        DeltaMovedLibrary(
          from: 'package:flutter/material.dart',
          to: 'package:material_ui/material_ui.dart',
          title: 'Migrate to material_ui.',
        ),
      ],
      unread: [
        DeltaUnreadFile(file: 'package:kit/fix_data.yaml', reason: 'bad'),
      ],
    ),
  );

  test('round-trips through JSON, ignoring meta', () {
    final json =
        jsonDecode(jsonEncode(knowledge.toJson())) as Map<String, Object?>;
    final read = DeltaKnowledge.fromJson({
      ...json,
      'meta': {'inputHash': 'x'},
    });
    expect(jsonEncode(read.toJson()), jsonEncode(knowledge.toJson()));
  });

  test('a delta without API lists says why', () {
    const missing = DeltaKnowledge(
      flutterVersion: '3.47.5',
      baseline: '3.16',
      coverage: 'partial',
      newestNotes: '3.47',
      notes: [],
      laterNotes: [],
      missing: 'the packages could not be fetched',
    );
    final read = DeltaKnowledge.fromJson(
      jsonDecode(jsonEncode(missing.toJson())) as Map<String, Object?>,
    );
    expect(read.apis, isNull);
    expect(read.missing, 'the packages could not be fetched');
    expect(read.languageVersion, isNull);
  });

  test('a missing field names the file', () {
    expect(
      () => DeltaKnowledge.fromJson({'flutterVersion': '3.47.5'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('delta.json'),
        ),
      ),
    );
  });
}
