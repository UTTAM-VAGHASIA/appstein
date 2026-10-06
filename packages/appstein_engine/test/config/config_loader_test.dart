import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

Matcher configError(String text, {int? line}) => isA<ConfigException>()
    .having((e) => e.message, 'message', contains(text))
    .having((e) => e.line, 'line', line ?? anything);

void main() {
  test('an empty file gives the defaults', () {
    expect(parseConfig('').toJson(), const AppsteinConfig().toJson());
    expect(
      parseConfig('# only a comment\n').toJson(),
      const AppsteinConfig().toJson(),
    );
  });

  test('parses the spec §7 example', () {
    final config = parseConfig('''
appstein: 1
packs:
  stack: official_mvvm
  platforms: [android, ios]
delta:
  baseline: "3.16"
verify:
  fast_timeout_seconds: 20
  build_on_full: true
  severity:
    ui.no_hardcoded_colors: warning
docs:
  enabled: true
  path: docs/app
packages:
  stale_after_months: 12
  allow: []
  deny: [some_bad_pkg]
integrations:
  agents: [claude, codex]
  graphify_export: false
  developer_knowledge_mcp: false
''');
    expect(config.verify.severity, {
      'ui.no_hardcoded_colors': Severity.warning,
    });
    expect(config.packages.deny, ['some_bad_pkg']);
  });

  test('an unknown key names the line and suggests the fix', () {
    expect(
      () => parseConfig('appstein: 1\npakages:\n  deny: []\n'),
      throwsA(configError('Did you mean "packages"?', line: 2)),
    );
  });

  test('an unquoted baseline explains the YAML number trap', () {
    expect(
      () => parseConfig('delta:\n  baseline: 3.20\n'),
      throwsA(configError('must be quoted', line: 2)),
    );
  });

  test('an unsupported format version is rejected', () {
    expect(
      () => parseConfig('appstein: 2\n'),
      throwsA(configError('format 2 is not supported')),
    );
  });

  test('values outside the allowed set are rejected', () {
    expect(
      () => parseConfig('packs:\n  platforms: [android, web]\n'),
      throwsA(configError('"web" is not allowed')),
    );
    expect(
      () => parseConfig('verify:\n  severity:\n    ui.x: loud\n'),
      throwsA(configError('must be error, warning or info')),
    );
    expect(
      () => parseConfig('verify:\n  fast_timeout_seconds: 0\n'),
      throwsA(configError('at least 1')),
    );
  });

  test('docs.path must stay inside the project', () {
    expect(
      () => parseConfig('docs:\n  path: /tmp/docs\n'),
      throwsA(configError('not absolute')),
    );
    expect(
      () => parseConfig('docs:\n  path: C:\\docs\n'),
      throwsA(configError('not absolute')),
    );
    expect(
      () => parseConfig('docs:\n  path: ../outside\n'),
      throwsA(configError('inside the project')),
    );
    expect(parseConfig('docs:\n  path: docs\\app\n').docs.path, 'docs/app');
  });

  group('docs.path keeps out of folders that are not for docs', () {
    for (final path in [
      '.appstein',
      '.appstein/docs',
      '.git/x',
      '.dart_tool',
      'build/docs',
      'lib',
      'lib/docs',
      'test',
      './lib/docs',
    ]) {
      test('refuses $path', () {
        expect(
          () => parseConfig('docs:\n  path: $path\n'),
          throwsA(
            configError(
              'docs.path must not be inside .appstein, .git, .dart_tool, '
              'build, lib or test',
              line: 2,
            ),
          ),
        );
      });
    }

    test('still accepts docs/lib and library', () {
      expect(parseConfig('docs:\n  path: docs/lib\n').docs.path, 'docs/lib');
      expect(parseConfig('docs:\n  path: library\n').docs.path, 'library');
    });
  });

  group('suppressions', () {
    test('reads id, path, reason and the line of each entry', () {
      final config = parseConfig(
        'suppressions:\n'
        '  - id: decision.drift\n'
        '    path: .appstein/decisions/0002-state.md\n'
        '    reason: Riverpod is being trialled in one feature.\n'
        '  - id: verify.test_required\n'
        '    path: lib/ui/**\n',
      );
      expect(config.suppressions, hasLength(2));
      expect(config.suppressions[0].id, 'decision.drift');
      expect(config.suppressions[0].path, '.appstein/decisions/0002-state.md');
      expect(
        config.suppressions[0].reason,
        'Riverpod is being trialled in one feature.',
      );
      expect(config.suppressions[0].line, 2);
      expect(config.suppressions[1].reason, isNull);
      expect(config.suppressions[1].line, 5);
      expect(config.toJson()['suppressions'], [
        {
          'id': 'decision.drift',
          'path': '.appstein/decisions/0002-state.md',
          'reason': 'Riverpod is being trialled in one feature.',
        },
        {'id': 'verify.test_required', 'path': 'lib/ui/**', 'reason': null},
      ]);
    });

    test('none by default, and an empty list is fine', () {
      expect(parseConfig('').suppressions, isEmpty);
      expect(parseConfig('suppressions: []\n').suppressions, isEmpty);
      expect(parseConfig('suppressions:\n').suppressions, isEmpty);
    });

    test('a blank reason is read as no reason', () {
      final config = parseConfig(
        'suppressions:\n  - id: docs.stale\n    path: docs/app/**\n'
        '    reason: "  "\n',
      );
      expect(config.suppressions.single.reason, isNull);
    });

    test('normalizes ./ and keeps globs', () {
      final config = parseConfig(
        'suppressions:\n  - id: docs.stale\n    path: ./docs/app/*.md\n'
        '    reason: x\n',
      );
      expect(config.suppressions.single.path, 'docs/app/*.md');
    });

    // Review Focus 3: a path is refused with its line, never matched loosely.
    for (final (yaml, message, line) in [
      ('suppressions: nope\n', 'suppressions must be a list', 1),
      ('suppressions:\n  - nope\n', 'must be a map', 2),
      ('suppressions:\n  - path: a\n    reason: b\n', 'needs an id', 2),
      (
        'suppressions:\n  - id: Bad\n    path: a\n',
        '"Bad" is not a check ID',
        2,
      ),
      ('suppressions:\n  - id: docs.stale\n    reason: b\n', 'needs a path', 2),
      (
        'suppressions:\n  - id: docs.stale\n    path: C:\\docs\n',
        'must use /',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: C:/docs\n',
        'must be relative',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: /docs\n',
        'must be relative',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: ../x\n',
        'inside the project',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: a/../../x\n',
        'inside the project',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: docs\\app\n',
        'must use /',
        3,
      ),
      (
        'suppressions:\n  - id: docs.stale\n    path: "[x"\n',
        'is not a valid pattern',
        3,
      ),
      ('suppressions:\n  - id: docs.stale\n    path: 3\n', 'must be text', 3),
      (
        'suppressions:\n  - id: docs.stale\n    path: a\n    why: b\n',
        'Unknown key "why"',
        4,
      ),
    ]) {
      test('refuses: $message', () {
        expect(
          () => parseConfig(yaml),
          throwsA(configError(message, line: line)),
        );
      });
    }
  });

  // Review Focus 4: malformed files must give a positioned error, never a crash.
  test('a list, a duplicate key or broken YAML gives a positioned error', () {
    expect(
      () => parseConfig('- a\n- b\n'),
      throwsA(configError('must be a map')),
    );
    expect(
      () => parseConfig('docs:\n  enabled: true\n  enabled: false\n'),
      throwsA(isA<ConfigException>().having((e) => e.line, 'line', isNotNull)),
    );
    expect(
      () => parseConfig('packs: [unclosed\n'),
      throwsA(isA<ConfigException>().having((e) => e.line, 'line', isNotNull)),
    );
  });

  test(
    'loadConfig returns null without a file and reads one in a spaced path',
    () {
      final dir = tempDir();
      expect(loadConfig(dir.path), isNull);
      File(
        p.join(dir.path, configFileName),
      ).writeAsStringSync('docs:\n  enabled: false\n');
      expect(loadConfig(dir.path)!.docs.enabled, isFalse);
    },
  );

  test('a leading BOM (Windows PowerShell writes one) is ignored', () {
    final config = parseConfig(
      '\uFEFFappstein: 1\npacks:\n  stack: official_mvvm\n',
    );
    expect(config.packs.stack, 'official_mvvm');
  });

  test('a file that is not valid UTF-8 is a ConfigException naming it', () {
    final dir = tempDir();
    File(
      p.join(dir.path, configFileName),
    ).writeAsBytesSync([0x61, 0x3a, 0x20, 0xff, 0xfe, 0x0a]);
    expect(
      () => loadConfig(dir.path),
      throwsA(
        isA<ConfigException>()
            .having((e) => e.message, 'message', contains('Could not read'))
            .having((e) => e.toString(), 'toString', contains(configFileName)),
      ),
    );
  });

  test('the error message includes the file path', () {
    final dir = tempDir();
    File(p.join(dir.path, configFileName)).writeAsStringSync('nope: 1\n');
    expect(
      () => loadConfig(dir.path),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.toString(),
          'toString',
          contains(configFileName),
        ),
      ),
    );
  });
}
