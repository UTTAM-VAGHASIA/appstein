import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  group('projectNameOf', () {
    test('reads the name from pubspec.yaml', () {
      expect(
        projectNameOf(utf8.encode('name: my_app\nversion: 1.0.0\n')),
        'my_app',
      );
    });

    test('is null for a missing, invalid or nameless pubspec', () {
      expect(projectNameOf(null), isNull);
      expect(projectNameOf(utf8.encode('name: [unclosed\n')), isNull);
      expect(projectNameOf(utf8.encode('- a list\n')), isNull);
      expect(projectNameOf(utf8.encode('name: 42\n')), isNull);
      expect(projectNameOf(utf8.encode('version: 1.0.0\n')), isNull);
      expect(projectNameOf(const [0xff, 0xfe]), isNull);
    });
  });

  test('platformFolders lists the platform folders that exist, in a fixed '
      'order', () {
    final root = tempDir().path;
    for (final name in ['windows', 'android', 'web', 'lib']) {
      Directory(p.join(root, name)).createSync();
    }
    // A file named like a platform is not a platform folder.
    File(p.join(root, 'ios')).writeAsStringSync('not a folder');
    expect(platformFolders(root), ['android', 'web', 'windows']);
  });

  group('appIdLines', () {
    NativeValue found(Object value) => NativeValue.found(value, at: 'x:1');

    NativeConfig config({NativeNode? android, NativeNode? ios}) =>
        NativeConfig({'android': ?android, 'ios': ?ios});

    NativeGroup android(
      NativeNode applicationId, {
      List<String> flavors = const [],
    }) => NativeGroup({
      'app': NativeGroup({
        'applicationId': applicationId,
        'flavors': NativeList([
          for (final name in flavors) NativeEntry(name, const {}),
        ]),
      }),
    });

    NativeGroup ios(Map<String, NativeNode> bundleIds) => NativeGroup({
      'xcode': NativeGroup({
        'configurations': NativeList([
          for (final MapEntry(:key, :value) in bundleIds.entries)
            NativeEntry(key, {'bundleIdentifier': value}),
        ]),
      }),
    });

    test('a found applicationId, and one bundle id when every '
        'configuration has the same', () {
      expect(
        appIdLines(
          config(
            android: android(found('dev.sample.probe_app')),
            ios: ios({
              'Debug': found('dev.sample.probeApp'),
              'Profile': found('dev.sample.probeApp'),
              'Release': found('dev.sample.probeApp'),
            }),
          ),
        ),
        [
          'Android applicationId: `dev.sample.probe_app`',
          'iOS bundle id: `dev.sample.probeApp`',
        ],
      );
    });

    test('bundle ids that differ are listed per configuration, by name', () {
      expect(
        appIdLines(
          config(
            ios: ios({
              'Release': found('com.example.app'),
              'Debug': found('com.example.app.dev'),
            }),
          ),
        ),
        [
          'iOS bundle id: Debug `com.example.app.dev`, Release `com.example.app`',
        ],
      );
    });

    test('flavors are counted, since they may change the id', () {
      expect(
        appIdLines(
          config(android: android(found('com.a'), flavors: ['dev', 'prod'])),
        ),
        [
          'Android applicationId: `com.a` (2 flavors may change it; see '
              '`map/native.json`)',
        ],
      );
      expect(
        appIdLines(
          config(android: android(found('com.a'), flavors: ['dev'])),
        ).single,
        contains('(1 flavor may change it;'),
      );
    });

    test('an id that is unknown, absent or uses Xcode variables is '
        'unknown, never guessed', () {
      expect(
        appIdLines(
          config(
            android: android(const NativeValue.unknown('set more than once')),
            ios: ios({
              'Debug': found(r'$(PRODUCT_BUNDLE_IDENTIFIER)'),
              'Release': found('com.example.app'),
            }),
          ),
        ),
        [
          'Android applicationId: unknown; see `map/native.json`',
          'iOS bundle id: unknown; see `map/native.json`',
        ],
      );
      expect(
        appIdLines(
          config(android: android(const NativeValue.absent('not set'))),
        ).single,
        'Android applicationId: unknown; see `map/native.json`',
      );
      expect(
        appIdLines(
          config(
            ios: NativeGroup({
              'xcode': NativeGroup({
                'configurations': const NativeValue.unknown('unreadable'),
              }),
            }),
          ),
        ).single,
        'iOS bundle id: unknown; see `map/native.json`',
      );
    });

    test('an id with any \$ (\${VAR} or \$VAR) is unknown, never shown', () {
      for (final id in [
        r'com.example.app${BUNDLE_SUFFIX}',
        r'com.example.$SUFFIX',
      ]) {
        expect(
          appIdLines(config(ios: ios({'Debug': found(id)}))).single,
          'iOS bundle id: unknown; see `map/native.json`',
        );
      }
      expect(
        appIdLines(
          config(android: android(found(r'com.example${APP_SUFFIX}'))),
        ).single,
        'Android applicationId: unknown; see `map/native.json`',
      );
    });

    test('a platform without its folder has no line; a failed pack says '
        'unknown', () {
      expect(
        appIdLines(
          config(
            android: const NativeValue.absent('no android/ folder'),
            ios: const NativeValue.error('StateError'),
          ),
        ),
        ['iOS bundle id: unknown; see `map/native.json`'],
      );
      expect(appIdLines(null), isEmpty);
    });
  });

  group('indexFeatures', () {
    test('most screens first, then by name; main files are the screens\' '
        'then the view models\', relative to the folder', () {
      final rows = indexFeatures(
        FeaturesMap.fromJson(
          jsonDecode(goldenText('features.json')) as Map<String, Object?>,
        ),
      );
      expect(
        [for (final row in rows) row.name],
        ['auth/login', 'booking', 'home', 'profile', 'settings'],
      );
      final home = rows.firstWhere((row) => row.name == 'home');
      expect(home.folder, 'lib/ui/home');
      expect(home.screens, 1);
      expect(home.mainFiles, [
        'widgets/home_screen.dart',
        'view_models/home_viewmodel.dart',
      ]);
    });

    test('a feature with more screens comes first; one with no screens or '
        'view models lists its files', () {
      Feature feature(
        String folder, {
        List<CodeRef> screens = const [],
        List<String> files = const [],
      }) => Feature(
        folder: folder,
        viewModels: const [],
        screens: screens,
        repositories: const [],
        services: const [],
        models: const [],
        tests: const [],
        files: files,
      );
      final rows = indexFeatures(
        FeaturesMap(
          features: {
            'a': feature('lib/ui/a', files: ['lib/ui/a/widgets/a_panel.dart']),
            'z': feature(
              'lib/ui/z',
              screens: const [
                CodeRef(name: 'Z1', file: 'lib/ui/z/widgets/z1.dart'),
                CodeRef(name: 'Z2', file: 'lib/ui/z/widgets/z2.dart'),
              ],
            ),
          },
        ),
      );
      expect([for (final row in rows) row.name], ['z', 'a']);
      expect(rows.first.screens, 2);
      expect(rows.first.mainFiles, ['widgets/z1.dart', 'widgets/z2.dart']);
      expect(rows.last.mainFiles, ['widgets/a_panel.dart']);
    });
  });

  group('parseDecision', () {
    test('reads the title and status, and the number from the file name', () {
      final decision = parseDecision(
        '0002-state.md',
        '---\nid: 0002\ntitle: State management with provider + '
            'ChangeNotifier\nstatus: accepted\ndate: 2026-10-02\n---\n'
            'Why: Flutter recommends it.\n',
      );
      expect(decision.id, '0002');
      expect(decision.title, 'State management with provider + ChangeNotifier');
      expect(decision.status, 'accepted');
      expect(decision.problem, isNull);
      expect(decisionNumber('notes.md'), isNull);
    });

    test('CRLF line ends and a multi-line title are read; the title becomes '
        'one line', () {
      final decision = parseDecision(
        '0003-x.md',
        '---\r\ntitle: |\r\n  Two\r\n  lines\r\nstatus: proposed\r\n---\r\n',
      );
      expect(decision.title, 'Two lines');
      expect(decision.status, 'proposed');
    });

    test('a leading BOM (Windows PowerShell writes one) is ignored', () {
      final bom = String.fromCharCode(0xFEFF);
      final decision = parseDecision(
        '0006-x.md',
        '$bom---\r\ntitle: Use provider\r\nstatus: accepted\r\n---\r\n',
      );
      expect(decision.problem, isNull);
      expect(decision.title, 'Use provider');
      expect(decision.status, 'accepted');
    });

    test('a very long title is shortened to 120 characters', () {
      final decision = parseDecision(
        '0004-x.md',
        '---\ntitle: ${'word ' * 60}\nstatus: accepted\n---\n',
      );
      expect(decision.title!.runes.length, 120);
      expect(decision.title, endsWith('…'));
    });

    for (final (text, problem) in [
      ('Just text.\n', 'it has no front matter'),
      (
        '---\ntitle: x\nstatus: accepted\n',
        'its front matter has no closing ---',
      ),
      ('---\ntitle: [unclosed\n---\n', 'its front matter is not valid YAML'),
      ('---\n- a\n---\n', 'its front matter is not a map'),
      ('---\nstatus: accepted\n---\n', 'it has no title'),
      (
        '---\ntitle: x\nstatus: done\n---\n',
        'its status is not accepted, proposed or superseded',
      ),
    ]) {
      test('unreadable: $problem', () {
        final decision = parseDecision('0005-x.md', text);
        expect(decision.problem, problem);
        expect(decision.id, '0005');
        expect(decision.title, isNull);
        expect(decision.status, isNull);
      });
    }
  });

  test('currentWorkLines drops blank lines at the ends and trailing spaces, '
      'and cuts long lines to 160 characters', () {
    expect(
      currentWorkLines('\n\n# Goal\r\n\r\nShip it.   \n${'x' * 200}\n\n'),
      ['# Goal', '', 'Ship it.', '${'x' * 159}…'],
    );
    expect(currentWorkLines('  \n\n'), isEmpty);
  });

  test('currentWorkLines ignores a leading BOM (Windows PowerShell writes '
      'one)', () {
    final bom = String.fromCharCode(0xFEFF);
    final lines = currentWorkLines('$bom# Goal\r\nShip it.\r\n');
    expect(lines, ['# Goal', 'Ship it.']);
    expect(lines.first.codeUnitAt(0), isNot(0xFEFF));
  });

  group('readIndexSources', () {
    late String root;

    setUp(() {
      root = tempDir().path;
      File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: my_app\n');
    });

    void write(String path, String text) =>
        File(p.joinAll([root, ...path.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);

    test('a new project: its name, no decisions, no current work', () {
      final sources = readIndexSources(root);
      expect(sources.projectName, 'my_app');
      expect(sources.platforms, isEmpty);
      expect(sources.decisions, isEmpty);
      expect(sources.decisionsError, isNull);
      expect(sources.currentWork, isEmpty);
      expect(sources.currentWorkError, isNull);
      expect(
        sources.inputs.keys,
        unorderedEquals(['pubspec.yaml', 'platforms']),
      );
    });

    test('decisions are read in file-name order; superseded ones and other '
        'files are left out, but every .md file is hashed', () {
      write(
        '.appstein/decisions/0002-b.md',
        '---\ntitle: B\nstatus: proposed\n---\n',
      );
      write(
        '.appstein/decisions/0001-a.md',
        '---\ntitle: A\nstatus: accepted\n---\n',
      );
      write(
        '.appstein/decisions/0003-old.md',
        '---\ntitle: Old\nstatus: superseded\n---\n',
      );
      write('.appstein/decisions/0004 with space.md', 'no front matter\n');
      write('.appstein/decisions/notes.txt', 'ignored');
      final sources = readIndexSources(root);
      expect(
        [for (final decision in sources.decisions) decision.file],
        ['0001-a.md', '0002-b.md', '0004 with space.md'],
      );
      expect(sources.decisions.last.problem, 'it has no front matter');
      expect(
        sources.inputs.keys,
        containsAll([
          'decisions/0001-a.md',
          'decisions/0002-b.md',
          'decisions/0003-old.md',
          'decisions/0004 with space.md',
        ]),
      );
      expect(sources.inputs.keys, isNot(contains('decisions/notes.txt')));
    });

    test('current work is read and hashed', () {
      write('.appstein/memory/current.md', '\n# Goal\n\nShip it.\n');
      final sources = readIndexSources(root);
      expect(sources.currentWork, ['# Goal', '', 'Ship it.']);
      expect(sources.inputs.keys, contains('memory/current.md'));
    });

    test(
      'an unreadable decisions folder or current.md is reported, not '
      'thrown',
      () {
        write(
          '.appstein/decisions/0001-a.md',
          '---\ntitle: A\nstatus: accepted\n---\n',
        );
        write('.appstein/memory/current.md', 'Goal\n');
        final decisions = p.join(root, '.appstein', 'decisions');
        final current = p.join(root, '.appstein', 'memory', 'current.md');
        Process.runSync('chmod', ['000', decisions, current]);
        addTearDown(
          () => Process.runSync('chmod', ['755', decisions, current]),
        );
        final sources = readIndexSources(root);
        expect(sources.decisions, isEmpty);
        expect(sources.decisionsError, isNotEmpty);
        expect(sources.currentWork, isEmpty);
        expect(sources.currentWorkError, isNotEmpty);
      },
      skip: Platform.isWindows
          ? 'chmod does not exist on Windows'
          : Platform.environment['USER'] == 'root'
          ? 'root reads files whatever their mode'
          : false,
    );
  });
}
