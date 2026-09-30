import 'package:test/test.dart';

import '../tool/src/guide_check.dart';
import 'support/temp_repo.dart';

void main() {
  test('reports a --since that is not a commit instead of crashing', () async {
    final repo = tempRepo();
    writeFile(repo, 'docs/guide/README.md', '<!-- covers: none -->\n# G\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
    final problems = await checkGuide(repo.path, since: 'nope');
    expect(
      problems.map((problem) => '$problem'),
      contains('--since: nope is not a commit.'),
    );
  });
}
