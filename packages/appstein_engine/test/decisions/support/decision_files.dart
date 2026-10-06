import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes the decision file [name] into the project at [root], as a person
/// would by hand, and returns its path.
String handDecision(
  String root,
  String name, {
  String? title,
  String status = 'accepted',
  String? supersedes,
  List<String> paths = const [],
  String why = 'because.',
  String eol = '\n',
}) {
  final file = File(p.join(root, '.appstein', 'decisions', name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      [
        '---',
        'title: ${title ?? 'Decision in $name'}',
        'status: $status',
        'date: 2026-10-01',
        if (supersedes != null) 'supersedes: $supersedes',
        if (paths.isNotEmpty) 'paths: [${paths.join(', ')}]',
        '---',
        'Why: $why',
        '',
      ].join(eol),
    );
  return file.path;
}

/// Every file below [folder] with its bytes, by its path from [folder], for
/// proving that nothing changed.
Map<String, List<int>> snapshotOf(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const {};
  return {
    for (final entity in dir.listSync(
      recursive: true,
    )..sort((a, b) => a.path.compareTo(b.path)))
      if (entity is File)
        p.relative(entity.path, from: folder).replaceAll(r'\', '/'): entity
            .readAsBytesSync(),
  };
}
