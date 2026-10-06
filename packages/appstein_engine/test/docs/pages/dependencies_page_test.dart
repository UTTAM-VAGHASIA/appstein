import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/docs_support.dart';

PackageDependency _package({
  String version = '1.0.0',
  String? constraint = '^1.0.0',
  String dependency = 'direct main',
  String source = 'hosted',
  List<String> usages = const [],
}) => PackageDependency(
  constraint: constraint,
  version: version,
  dependency: dependency,
  source: source,
  usages: usages,
);

String _render(Map<String, PackageDependency> packages) {
  final sections = const DependenciesPage().sections(
    sampleKnowledge(deps: DepsMap(packages: packages)),
  );
  expect(sections.single.path, 'dependencies.md');
  expect(sections.single.title, 'Dependencies');
  return sections.single.markdown;
}

void main() {
  test('groups the packages by how the app depends on them', () {
    expect(
      _render({
        'yaml': _package(dependency: 'transitive', constraint: null),
        'test': _package(dependency: 'direct dev', version: '1.32.0'),
        'go_router': _package(
          version: '18.1.0',
          constraint: '>=18.0.0 <19.0.0',
          usages: const ['lib/routing/router.dart'],
        ),
        'async': _package(dependency: 'transitive', constraint: null),
        'flutter': _package(
          version: '0.0.0',
          constraint: null,
          source: 'sdk',
          usages: const [
            'lib/main.dart',
            'lib/ui/home/widgets/home_screen.dart',
          ],
        ),
        'path': _package(dependency: 'direct overridden'),
      }),
      'The versions are the ones `pubspec.lock` resolved.\n'
      '\n'
      '## Direct\n'
      '\n'
      '| Package | Version | Constraint | Source | Used in |\n'
      '|---|---|---|---|---|\n'
      '| `flutter` | 0.0.0 |  | sdk | 2 files: '
      '[lib/main.dart](../../lib/main.dart), '
      '[lib/ui/home/widgets/home_screen.dart]'
      '(../../lib/ui/home/widgets/home_screen.dart) |\n'
      '| `go_router` | 18.1.0 | `>=18.0.0 <19.0.0` | hosted | 1 file: '
      '[lib/routing/router.dart](../../lib/routing/router.dart) |\n'
      '\n'
      '## Dev\n'
      '\n'
      '| Package | Version | Constraint | Source | Used in |\n'
      '|---|---|---|---|---|\n'
      '| `test` | 1.32.0 | `^1.0.0` | hosted | not imported |\n'
      '\n'
      '## Overridden\n'
      '\n'
      '| Package | Version | Constraint | Source | Used in |\n'
      '|---|---|---|---|---|\n'
      '| `path` | 1.0.0 | `^1.0.0` | hosted | not imported |\n'
      '\n'
      '## Transitive\n'
      '\n'
      '2 packages come in through the ones above.\n'
      '\n'
      '| Package | Version | Source |\n'
      '|---|---|---|\n'
      '| `async` | 1.0.0 | hosted |\n'
      '| `yaml` | 1.0.0 | hosted |',
    );
  });

  test('leaves out a group without packages', () {
    final text = _render({'test': _package(dependency: 'direct dev')});
    expect(text, contains('## Dev'));
    expect(text, isNot(contains('## Direct')));
    expect(text, isNot(contains('## Overridden')));
    expect(text, isNot(contains('## Transitive')));
  });

  test('names five files, then counts the rest', () {
    List<String> files(int count) => [
      for (var i = 0; i < count; i++) 'lib/f$i.dart',
    ];
    final five = _render({'a': _package(usages: files(5))});
    expect(five, contains('| 5 files: '));
    expect(five, contains('lib/f4.dart'));
    expect(five, isNot(contains('more')));
    final six = _render({'a': _package(usages: files(6))});
    expect(six, contains('| 6 files: '));
    expect(six, isNot(contains('lib/f5.dart')));
    expect(six, contains('(../../lib/f4.dart) and 1 more |'));
  });

  test('one transitive package is singular', () {
    expect(
      _render({'a': _package(dependency: 'transitive')}),
      contains('1 package comes in through the ones above.'),
    );
  });

  test('a kind of dependency it does not know gets its own group', () {
    final text = _render({'a': _package(dependency: 'direct|odd')});
    expect(text, contains(r'## direct\|odd'));
    expect(text, contains('| `a` |'));
  });

  test('says so when there are no packages', () {
    expect(_render(const {}), '`pubspec.lock` lists no packages.');
  });
}
