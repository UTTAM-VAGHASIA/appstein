import 'package:appstein_protocol/appstein_protocol.dart';

import '../doc_page.dart';
import '../docs_knowledge.dart';
import '../markdown_text.dart';

/// `dependencies.md` (spec §6.9): each package, its version and where the
/// app uses it. The package gate's verdict joins it with the gate (§9.4).
final class DependenciesPage implements DocPage {
  /// Creates the page source.
  const DependenciesPage();

  /// The page's path inside the docs folder.
  static const path = 'dependencies.md';

  /// How many of a package's files are named before `and N more`.
  static const shownUsages = 5;

  static const _groups = {
    'direct main': 'Direct',
    'direct dev': 'Dev',
    'direct overridden': 'Overridden',
  };
  static const _transitive = 'transitive';

  @override
  String get id => 'dependencies';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final packages = knowledge.deps.packages;
    final names = packages.keys.toList()..sort();
    List<String> of(String dependency) => [
      for (final name in names)
        if (packages[name]!.dependency == dependency) name,
    ];
    final other = {
      for (final package in packages.values)
        if (!_groups.containsKey(package.dependency) &&
            package.dependency != _transitive)
          package.dependency,
    }.toList()..sort();

    final parts = <String>[
      if (names.isEmpty)
        '`pubspec.lock` lists no packages.'
      else
        'The versions are the ones `pubspec.lock` resolved.',
      for (final MapEntry(key: dependency, value: heading) in {
        ..._groups,
        for (final dependency in other) dependency: mdText(dependency),
      }.entries)
        if (of(dependency) case final group when group.isNotEmpty)
          '## $heading\n\n'
              '${mdTable(const ['Package', 'Version', 'Constraint', 'Source', 'Used in'], [for (final name in group) _row(knowledge, name, packages[name]!)])}',
      if (of(_transitive) case final group when group.isNotEmpty)
        '## Transitive\n\n'
            '${group.length == 1 ? '1 package comes' : '${group.length} packages come'} '
            'in through the ones above.\n\n'
            '${mdTable(const ['Package', 'Version', 'Source'], [
              for (final name in group) [mdCode(name), mdText(packages[name]!.version), mdText(packages[name]!.source)],
            ])}',
    ];
    return [
      DocSection(
        path: path,
        title: 'Dependencies',
        markdown: parts.map((part) => part.trimRight()).join('\n\n'),
      ),
    ];
  }

  List<String> _row(
    DocsKnowledge knowledge,
    String name,
    PackageDependency package,
  ) => [
    mdCode(name),
    mdText(package.version),
    mdCode(package.constraint ?? ''),
    mdText(package.source),
    _usedIn(knowledge, package.usages),
  ];

  String _usedIn(DocsKnowledge knowledge, List<String> usages) {
    if (usages.isEmpty) return 'not imported';
    final links = [
      for (final file in usages.take(shownUsages))
        projectLink(docsPath: knowledge.docsPath, page: path, target: file),
    ].join(', ');
    final rest = usages.length - shownUsages;
    return '${usages.length == 1 ? '1 file' : '${usages.length} files'}: '
        '$links${rest > 0 ? ' and $rest more' : ''}';
  }
}
