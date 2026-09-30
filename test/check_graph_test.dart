import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/graphify.dart';
import 'support/temp_repo.dart';

final _script = p.absolute('tool', 'check_graph.py');
final _fixture = p.absolute('test', 'support', 'graphify_fixture.py');

const _update = 'Run /graphify . --update before relying on it.';

void main() {
  late String python;
  late Directory repo;

  /// Runs graphify's Python in [repo], without the caller's `GRAPHIFY_OUT`
  /// or `PYTHONPATH`, which would move the graph or shadow graphify.
  ProcessResult runPython(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) => Process.runSync(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: {
      for (final entry in Platform.environment.entries)
        if (!const {
          'GRAPHIFY_OUT',
          'PYTHONPATH',
        }.contains(entry.key.toUpperCase()))
          entry.key: entry.value,
      ...environment,
    },
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  /// Fakes `/graphify . --update` extracting [docs] with [prompt].
  void extract(
    String prompt,
    List<String> docs, {
    List<String> flags = const [],
  }) {
    final result = runPython([_fixture, prompt, ...flags, ...docs]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  /// Writes a graph.json with one node from each of [sources].
  void graph(List<String> sources) => writeFile(
    repo,
    'graphify-out/graph.json',
    jsonEncode({
      'nodes': [
        for (final (i, source) in sources.indexed)
          {'id': 'n$i', 'source_file': source},
      ],
      'links': <Object>[],
    }),
  );

  ({int code, String output}) check([
    List<String> arguments = const [],
    Map<String, String> environment = const {},
  ]) {
    final result = runPython([_script, ...arguments], environment: environment);
    return (
      code: result.exitCode,
      output: '${result.stdout}${result.stderr}'.trim(),
    );
  }

  setUp(() {
    python =
        graphifyPython ??
        fail(
          'APPSTEIN_REQUIRE_GRAPHIFY=1, but no Python with graphify was found',
        );
    repo = tempRepo();
    writeFile(repo, '.gitignore', 'graphify-out/\n');
    writeFile(repo, 'docs/a.md', '# A\n\nalpha\n');
    writeFile(repo, 'docs/b.md', '# B\n\nbeta\n');
    writeFile(repo, 'lib/c.dart', 'void main() {}\n');
  });

  group('with graphify', skip: skipWithoutGraphify, () {
    void upToDate() {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'lib/c.dart']);
    }

    test('says the graph is current, or nothing with --quiet', () {
      upToDate();
      expect(check(), (
        code: 0,
        output: 'graphify: the graph is current (2 docs checked).',
      ));
      expect(check(['--quiet']), (code: 0, output: ''));
    });

    test('names a changed doc and a new doc', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 2 docs (new or changed: '
            'docs/b.md, docs/n.md). $_update',
      ));
    });

    test('counts an extraction made with any prompt', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      extract('another agent prompt', ['docs/b.md']);
      expect(check().code, 0);
    });

    test('counts a deep-mode extraction', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--deep']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check().code, 0);
    });

    test('treats a partial extraction as missing', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--partial']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (new or changed: '
            'docs/b.md). $_update',
      ));
    });

    test('names a doc that is extracted but missing from the graph', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
    });

    test('names a deleted doc still in the graph, but not a deleted code '
        'file', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'docs/old.md', 'lib/gone.dart']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (deleted or no longer '
            'scanned: docs/old.md). $_update',
      ));
    });

    test('matches graph paths written with backslashes or as absolute '
        'paths', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph([r'docs\a.md', p.join(repo.path, 'docs', 'b.md')]);
      expect(check().code, 0);
    });

    test('lists at most five names per reason', () {
      upToDate();
      for (var i = 0; i < 7; i++) {
        writeFile(repo, 'docs/m$i.md', '# M$i\n');
      }
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 7 docs (new or changed: '
            'docs/m0.md, docs/m1.md, docs/m2.md, docs/m3.md, docs/m4.md and '
            '2 more). $_update',
      ));
    });

    test('cannot run without a graph, and says so in UTF-8', () {
      final result = check();
      expect(result.code, 3);
      expect(
        result.output,
        startsWith(
          'graphify: the graph check could not run: there is no graph yet',
        ),
      );
      // The temp repo's path contains "tëst"; on Windows this fails unless
      // the script prints UTF-8.
      expect(result.output, contains('tëst'));
    });

    test("cannot run when graphify doesn't have what it calls", () {
      upToDate();
      // A fake, empty graphify package that shadows the real one, as a
      // graphify release that moved its functions would.
      writeFile(repo, 'fake/graphify/__init__.py', '');
      final result = check(const [], {'PYTHONPATH': p.join(repo.path, 'fake')});
      expect(result.code, 3);
      expect(
        result.output,
        startsWith('graphify: the graph check could not run: '),
      );
    });

    test('rejects an unknown argument', () {
      expect(check(['--nope']), (
        code: 3,
        output: 'usage: check_graph.py [--quiet] (unknown: --nope)',
      ));
    });
  });
}
