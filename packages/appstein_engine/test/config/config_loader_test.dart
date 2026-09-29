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
