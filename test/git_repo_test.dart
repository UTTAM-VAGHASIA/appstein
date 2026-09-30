import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/git_repo.dart';
import 'support/temp_repo.dart';

void main() {
  late Directory repo;
  late GitRepo git;

  setUp(() {
    repo = tempRepo();
    git = GitRepo(repo.path);
    writeFile(repo, '.gitignore', 'build/\n');
    writeFile(repo, 'packages/a/lib/a.dart', 'a');
    writeFile(repo, 'docs/guide/README.md', '# Guide\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
  });

  test('files() lists tracked and untracked files, not ignored or deleted '
      'ones', () {
    writeFile(repo, 'tool/new tool.dart', 'x');
    writeFile(repo, 'build/out.txt', 'x');
    File(p.join(repo.path, 'docs', 'guide', 'README.md')).deleteSync();
    expect(git.files(), [
      '.gitignore',
      'packages/a/lib/a.dart',
      'tool/new tool.dart',
    ]);
  });

  test('changedSince() compares the merge base with the working tree', () {
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    runGit(repo, ['mv', 'packages/a/lib/a.dart', 'packages/a/lib/b.dart']);
    runGit(repo, ['commit', '-q', '-m', 'rename']);
    runGit(repo, ['switch', '-q', 'main']);
    writeFile(repo, 'main-only.txt', 'x');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'main moves on']);
    runGit(repo, ['switch', '-q', 'feature']);
    writeFile(repo, 'docs/guide/README.md', '# Changed\n');
    writeFile(repo, 'tool/untracked.dart', 'x');
    expect(git.changedSince('main'), [
      'docs/guide/README.md',
      'packages/a/lib/a.dart',
      'packages/a/lib/b.dart',
      'tool/untracked.dart',
    ]);
  });

  test('messagesSince() returns the messages after the merge base', () {
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    writeFile(repo, 'x.txt', 'x');
    runGit(repo, ['add', '.']);
    runGit(repo, [
      'commit',
      '-q',
      '-m',
      'Change x\n\nDocs-Checked: doctor.md - only a rename',
    ]);
    final messages = git.messagesSince('main');
    expect(messages, hasLength(1));
    expect(
      messages.single,
      contains('Docs-Checked: doctor.md - only a rename'),
    );
  });

  test('hasCommit() is false for unknown and all-zero revisions', () {
    expect(git.hasCommit('main'), isTrue);
    expect(git.hasCommit('nope'), isFalse);
    expect(git.hasCommit('0' * 40), isFalse);
  });

  test('a failing git command throws GitException', () {
    expect(() => git.changedSince('nope'), throwsA(isA<GitException>()));
  });

  test('ignores GIT_DIR, which a git hook sets', () {
    final other = tempRepo();
    writeFile(other, 'other.txt', 'x');
    final fromHook = GitRepo(
      repo.path,
      environment: {...gitEnvironment(), 'GIT_DIR': p.join(other.path, '.git')},
    );
    expect(fromHook.files(), contains('packages/a/lib/a.dart'));
    expect(fromHook.files(), isNot(contains('other.txt')));
  });

  test('fileAt() reads a file at the merge base, or null when it was not '
      'there', () {
    writeFile(repo, 'docs/guide/a b ë.md', '# Spaced\r\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'spaced']);
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    writeFile(repo, 'docs/guide/README.md', '# Changed\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'change']);
    expect(git.fileAt('main', 'docs/guide/README.md'), '# Guide\n');
    expect(git.fileAt('main', 'docs/guide/a b ë.md'), '# Spaced\r\n');
    expect(git.fileAt('main', 'docs/guide/new.md'), isNull);
  });
}
