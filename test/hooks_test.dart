import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/hooks.dart';
import 'support/temp_repo.dart';

const graphify =
    '#!/bin/sh\n# graphify-hook-start\n(\n  echo graph\n)\n'
    '# graphify-hook-end\n';

bool _hasSh() {
  try {
    return Process.runSync('sh', ['-c', 'exit 0']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final block = hookBlocks['post-merge']!;

  test('every block is marked and runs in a subshell', () {
    expect(hookBlocks.keys, ['post-commit', 'post-merge', 'post-rewrite']);
    for (final text in hookBlocks.values) {
      expect(text, startsWith('$hookBlockStart\n'));
      expect(text, endsWith(hookBlockEnd));
      expect(text, contains('\n(\n'));
      expect(text, contains('\n)\n'));
    }
  });

  test('every block is valid sh', () {
    final folder = tempFolder();
    for (final MapEntry(key: name, value: text) in hookBlocks.entries) {
      File(
        p.join(folder.path, name),
      ).writeAsStringSync(upsertHookBlock(null, text));
      final result = Process.runSync('sh', [
        '-n',
        name,
      ], workingDirectory: folder.path);
      expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
    }
  }, skip: _hasSh() ? false : 'sh is not on PATH');

  test('upsert creates a file with a shebang', () {
    expect(upsertHookBlock(null, block), '#!/bin/sh\n$block\n');
  });

  test("upsert appends after other content, such as graphify's block", () {
    expect(upsertHookBlock(graphify, block), '$graphify\n$block\n');
  });

  test('upsert replaces an older Appstein block in place, and is '
      'idempotent', () {
    const old =
        '#!/bin/sh\n$hookBlockStart\necho old\n$hookBlockEnd\n'
        '# graphify-hook-start\n# graphify-hook-end\n';
    final updated = upsertHookBlock(old, block);
    expect(
      updated,
      '#!/bin/sh\n$block\n# graphify-hook-start\n# graphify-hook-end\n',
    );
    expect(upsertHookBlock(updated, block), updated);
  });

  test('upsert refuses a start marker without an end marker', () {
    expect(
      () => upsertHookBlock('#!/bin/sh\n$hookBlockStart\n', block),
      throwsFormatException,
    );
  });

  test('remove keeps other content, and is null when only the shebang is '
      'left', () {
    expect(removeHookBlock(upsertHookBlock(graphify, block)), graphify);
    expect(removeHookBlock(upsertHookBlock(null, block)), isNull);
    expect(removeHookBlock(graphify), graphify);
  });

  test('installHookBlocks installs, reports up to date, and removes', () {
    final hooks = p.join(tempFolder().path, 'hooks');
    expect(installHookBlocks(hooks), [
      'post-commit: installed',
      'post-merge: installed',
      'post-rewrite: installed',
    ]);
    expect(installHookBlocks(hooks), [
      'post-commit: up to date',
      'post-merge: up to date',
      'post-rewrite: up to date',
    ]);
    expect(installHookBlocks(hooks, remove: true), [
      'post-commit: removed (file deleted)',
      'post-merge: removed (file deleted)',
      'post-rewrite: removed (file deleted)',
    ]);
    expect(Directory(hooks).listSync(), isEmpty);
  });

  group('in a real repo, run by git', () {
    late Directory repo;
    late File log;
    const env = {'APPSTEIN_SKIP_DOCS_HOOK': '1'};

    String head() => runGit(repo, ['rev-parse', 'HEAD']).trim();
    void commit(String file) {
      writeFile(repo, file, file);
      runGit(repo, ['add', '.'], environment: env);
      runGit(repo, ['commit', '-q', '-m', file], environment: env);
    }

    List<String> logged() =>
        log.existsSync() ? log.readAsLinesSync() : const [];

    setUp(() {
      repo = tempRepo();
      final hooks = p.join(repo.path, '.git', 'hooks');
      log = File(p.join(repo.path, '.git', 'checkout.log'));
      // Stands in for graphify's post-checkout rebuild: it logs its
      // arguments.
      final fake = File(p.join(hooks, 'post-checkout'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$1 \$2 \$3" >> "\$(git rev-parse --git-dir)/'
          'checkout.log"\n',
        );
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', fake.path]);
      installHookBlocks(hooks);
      commit('a.txt');
    });

    test('post-merge replays a fast-forward as a checkout', () {
      final a = head();
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('b.txt');
      final b = head();
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      runGit(repo, ['merge', '-q', '--ff-only', 'feature'], environment: env);
      expect(logged().last, '$a $b 1');
    });

    test('post-rewrite replays a rebase, but not an amend', () {
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('c.txt');
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      commit('d.txt');
      runGit(repo, ['switch', '-q', 'feature'], environment: env);
      final before = logged().length;
      runGit(repo, [
        'commit',
        '-q',
        '--amend',
        '-m',
        'c amended',
      ], environment: env);
      expect(logged(), hasLength(before));
      final oldTip = head();
      runGit(repo, ['rebase', '-q', 'main'], environment: env);
      expect(logged().last, '$oldTip ${head()} 1');
    });
  });

  group('the graph check, run by git', () {
    late Directory repo;
    late File log;
    late File fakePython;
    const env = {'APPSTEIN_SKIP_DOCS_HOOK': '1'};

    List<String> logged() =>
        log.existsSync() ? log.readAsLinesSync() : const [];

    /// Commits [file] and returns everything git and its hooks printed.
    String commit(String file, {Map<String, String> extra = const {}}) {
      writeFile(repo, file, file);
      runGit(repo, ['add', '.'], environment: {...env, ...extra});
      final result = gitResult(
        repo,
        ['commit', '-q', '-m', file],
        environment: {...env, ...extra},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}${result.stderr}';
    }

    setUp(() {
      repo = tempRepo();
      log = File(p.join(repo.path, '.git', 'python.log'));
      // Stands in for graphify's Python. It logs its arguments and exits 1,
      // as the real check does when the graph is behind. Its name has a
      // space, like "C:\Program Files\…".
      fakePython = File(p.join(repo.path, '.git', 'fake python'))
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$*" >> "\$(git rev-parse --git-dir)/'
          'python.log"\nexit 1\n',
        );
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', fakePython.path]);
      }
      writeFile(repo, '.gitignore', 'graphify-out/\n');
      writeFile(repo, 'tool/check_graph.py', '# stand-in\n');
      writeFile(repo, 'graphify-out/graph.json', '{}');
      writeFile(repo, 'graphify-out/.graphify_python', fakePython.path);
      installHookBlocks(p.join(repo.path, '.git', 'hooks'));
    });

    test('after a commit, runs the check quietly with graphify\'s Python, '
        'and prints nothing of its own', () {
      final output = commit('a.txt');
      expect(logged(), ['tool/check_graph.py --quiet']);
      expect(output, isNot(contains('graphify:')));
    });

    test('reads an interpreter path written with CRLF', () {
      writeFile(
        repo,
        'graphify-out/.graphify_python',
        '${fakePython.path}\r\n',
      );
      commit('a.txt');
      expect(logged(), hasLength(1));
    });

    test('is silent with APPSTEIN_SKIP_GRAPH_HOOK=1, without a graph, and '
        'without the script', () {
      final skipped = commit('a.txt', extra: {'APPSTEIN_SKIP_GRAPH_HOOK': '1'});
      File(p.join(repo.path, 'graphify-out', 'graph.json')).deleteSync();
      final noGraph = commit('b.txt');
      writeFile(repo, 'graphify-out/graph.json', '{}');
      File(p.join(repo.path, 'tool', 'check_graph.py')).deleteSync();
      final noScript = commit('c.txt');
      expect(logged(), isEmpty);
      for (final output in [skipped, noGraph, noScript]) {
        expect(output, isNot(contains('graphify:')));
      }
    });

    test('says so when graphify\'s Python is missing, and the commit still '
        'succeeds', () {
      const message =
          "graphify: the graph check could not run: "
          "graphify-out/.graphify_python doesn't name graphify's Python. "
          'Run /graphify . --update to set it.';
      writeFile(
        repo,
        'graphify-out/.graphify_python',
        p.join(repo.path, 'no such python'),
      );
      expect(commit('a.txt'), contains(message));
      File(p.join(repo.path, 'graphify-out', '.graphify_python')).deleteSync();
      expect(commit('b.txt'), contains(message));
      expect(logged(), isEmpty);
    });

    test('runs once after a merge, not during a rebase, once after it, and '
        'not again for an amend', () {
      commit('a.txt');
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('b.txt');
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      commit('c.txt');
      expect(logged(), hasLength(3));
      runGit(repo, ['merge', '-q', '--no-edit', 'feature'], environment: env);
      expect(logged(), hasLength(4), reason: 'post-merge');
      runGit(repo, [
        'switch',
        '-q',
        '-c',
        'topic',
        'feature',
      ], environment: env);
      commit('d.txt');
      commit('e.txt');
      expect(logged(), hasLength(6));
      runGit(repo, ['rebase', '-q', 'main'], environment: env);
      expect(
        logged(),
        hasLength(7),
        reason: 'post-rewrite once; post-commit skipped while rebasing',
      );
      runGit(repo, [
        'commit',
        '-q',
        '--amend',
        '-m',
        'e amended',
      ], environment: env);
      expect(logged(), hasLength(8), reason: 'post-commit only');
    });
  });
}
