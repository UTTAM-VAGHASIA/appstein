import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/generators.dart';

/// `dart test test` runs from the repo root, and these generators read the
/// real repo: that is the point of them.
final root = Directory.current.path;

void main() {
  test('doctor-checks lists every default check in order, with its doc '
      'comment and a working link', () {
    final rows = renderDoctorChecks(root).split('\n');
    expect(rows.take(2), [
      '| # | ID | Shown as | What it checks | Code |',
      '|---|---|---|---|---|',
    ]);
    final checks = defaultDoctorChecks();
    expect(rows.skip(2), hasLength(checks.length));
    for (var i = 0; i < checks.length; i++) {
      final row = rows[i + 2];
      expect(
        row,
        startsWith('| ${i + 1} | `${checks[i].id}` | ${checks[i].title} | '),
      );
      final link = RegExp(r'\]\(\.\./\.\./([^)]+)\) \|$').firstMatch(row);
      expect(link, isNotNull, reason: row);
      expect(File(p.join(root, link!.group(1))).existsSync(), isTrue);
    }
    expect(
      rows.join('\n'),
      contains('Checks the JDK Flutter actually uses for Android builds'),
    );
  });

  test('exit-codes lists ExitCodes with their doc comments, by code', () {
    expect(
      renderExitCodes(root),
      startsWith(
        '| Code | Name | Meaning |\n|---|---|---|\n'
        '| `0` | `ExitCodes.ok` | No errors. |\n'
        '| `1` | `ExitCodes.errorsFound` | Errors found. Used by the CLI and '
        'CI. |\n'
        '| `3` | `ExitCodes.appsteinFailed` | Appstein itself failed: bad '
        'usage, a bad environment or a crash. |',
      ),
    );
  });

  test('cli-help shows the top-level help and each command', () async {
    final text = await renderCliHelp();
    expect(
      text,
      startsWith(
        '```text\n\$ appstein --help\nA knowledge and verification layer',
      ),
    );
    expect(text, contains('\$ appstein help doctor\nCheck your environment'));
    expect('```'.allMatches(text), hasLength(4));
  });

  test('ci-jobs lists the triggers, each job, where it runs and its '
      'steps', () {
    final text = renderCiJobs(root);
    expect(
      text,
      contains(
        'Triggers: `push` (`main`), `pull_request`, '
        '`workflow_dispatch`.',
      ),
    );
    for (final job in ['analyze', 'test', 'build', 'docs', 'min-sdk']) {
      expect(text, contains('**`$job`** runs on'));
    }
    expect(
      text,
      contains(
        '**`test`** runs on `ubuntu-latest`, `windows-latest`, '
        '`macos-latest`:',
      ),
    );
    expect(text, contains('1. `actions/checkout@v4`'));
    expect(text, contains('. Developer guide check'));
  });

  test('package-graph draws the workspace dependencies', () {
    expect(
      renderPackageGraph(root),
      startsWith(
        '```mermaid\ngraph LR\n'
        '  appstein_cli --> appstein_engine\n'
        '  appstein_cli --> appstein_protocol\n'
        '  appstein_engine --> appstein_protocol\n'
        '  appstein_lints --> appstein_protocol\n```',
      ),
    );
  });

  test('renderSections renders all five sections', () async {
    expect(
      (await renderSections(root)).keys,
      unorderedEquals([
        'cli-help',
        'exit-codes',
        'doctor-checks',
        'ci-jobs',
        'package-graph',
      ]),
    );
  });
}
