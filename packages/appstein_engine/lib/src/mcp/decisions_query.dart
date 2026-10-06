import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../decisions/decision_store.dart';
import 'tool_answer.dart';

/// One decision as the `decisions` and `record_decision` tools return it
/// (spec §8), with its [score] for a word search.
Map<String, Object?> decisionJson(DecisionEntry entry, {int? score}) {
  final record = entry.record;
  return {
    'number': ?record.numberText,
    'title': record.title,
    'status': entry.status.jsonName,
    if (entry.status != record.status) 'statusInFile': record.status.jsonName,
    'date': ?record.date,
    'why': record.why,
    'paths': record.paths,
    'checks': record.checks,
    'file': decisionPath(record.file),
    if (record.supersedes case final number?)
      'supersedes': decisionNumberText(number),
    'supersededBy': ?entry.supersededBy?.numberText,
    'score': ?score,
  };
}

/// The `decisions` tool (spec §8): the project's [decisions] for [topic].
///
/// Without a topic, every decision in force. With the path of a project
/// file, the decisions in force whose `paths` cover it. With words, the
/// decisions that mention them, best match first, superseded ones
/// included. Every reply reports unreadable files, duplicate numbers and
/// other problems (spec §6.7).
///
/// With [projectRoot], the project's folder, an absolute path is read from
/// that folder, and a topic with a `/` or a dot counts as a path only when
/// it starts with a file or folder the project has, so `CI/CD` and
/// `Node.js` are searched as words.
ToolAnswer decisionsInfo(
  DecisionSet decisions, {
  String? topic,
  String? projectRoot,
}) {
  if (decisions.folderProblem case final problem?) {
    return ToolRefusal('`.appstein/decisions/` could not be read ($problem).');
  }
  final asked = topic?.trim() ?? '';
  final problems = [...decisions.problems];
  final String mode;
  final String summary;
  final List<Map<String, Object?>> found;
  int? withoutPaths;
  final asPath = asked.isEmpty ? null : _pathTopic(asked, projectRoot);

  if (asked.isEmpty) {
    mode = 'all';
    final active = decisions.active;
    found = [for (final entry in active) decisionJson(entry)];
    summary = _allSummary(decisions);
  } else if (asPath != null) {
    mode = 'path';
    final path = asPath.path;
    final active = decisions.active;
    found = [
      for (final entry in active)
        if (!asPath.outside && _covers(entry.record, path, problems))
          decisionJson(entry),
    ];
    final everywhere = active
        .where((entry) => entry.record.paths.isEmpty)
        .length;
    withoutPaths = everywhere;
    summary = [
      if (asPath.outside)
        "$path is outside the project folder, so no decision's paths cover "
            'it.'
      else
        switch (found.length) {
          0 => "No decision's paths cover $path.",
          1 => '1 decision covers $path.',
          final count => '$count decisions cover $path.',
        },
      if (everywhere == 1)
        '1 more lists no paths and applies everywhere; call decisions() '
            'without a topic to read it.',
      if (everywhere > 1)
        '$everywhere more list no paths and apply everywhere; call '
            'decisions() without a topic to read them.',
    ].join(' ');
  } else {
    mode = 'words';
    final words = [
      for (final match in RegExp(
        r'[\p{L}\p{N}]+',
        unicode: true,
      ).allMatches(asked.toLowerCase()))
        match.group(0)!,
    ];
    final scored =
        [
          for (final entry in decisions.entries)
            (entry: entry, score: _score(entry.record, words)),
        ].where((scored) => scored.score > 0).toList()..sort((a, b) {
          if (a.score != b.score) return b.score.compareTo(a.score);
          if (a.entry.active != b.entry.active) return a.entry.active ? -1 : 1;
          return (b.entry.record.number ?? 0).compareTo(
            a.entry.record.number ?? 0,
          );
        });
    found = [
      for (final (:entry, :score) in scored) decisionJson(entry, score: score),
    ];
    summary = switch (found.length) {
      0 => 'No decision matches "$asked".',
      1 => '1 decision matches "$asked".',
      final count => '$count decisions match "$asked".',
    };
  }

  final unreadable = decisions.unreadable.length;
  return ToolReply(
    {
      'mode': mode,
      if (asked.isNotEmpty) 'topic': asPath?.path ?? asked,
      'decisions': found,
      'superseded': decisions.entries.length - decisions.active.length,
      'withoutPaths': ?withoutPaths,
      'unreadable': [
        for (final file in decisions.unreadable)
          {'file': decisionPath(file.file), 'problem': file.problem},
      ],
      'duplicates': [
        for (final MapEntry(key: number, value: files)
            in decisions.duplicates.entries)
          {
            'number': decisionNumberText(number),
            'files': [for (final file in files) decisionPath(file)],
          },
      ],
      'problems': problems,
    },
    [
      summary,
      if (unreadable == 1) '1 decision file is unreadable.',
      if (unreadable > 1) '$unreadable decision files are unreadable.',
      for (final MapEntry(key: number, value: files)
          in decisions.duplicates.entries)
        'Number ${decisionNumberText(number)} is used by ${files.length} '
            'files; rename one.',
      ...problems,
    ].join(' '),
  );
}

String _allSummary(DecisionSet decisions) {
  final active = decisions.active;
  final superseded = decisions.entries.length - active.length;
  final gone = switch (superseded) {
    0 => null,
    1 => '1 is superseded.',
    _ => '$superseded are superseded.',
  };
  if (active.isEmpty) {
    return gone == null
        ? 'No decisions are recorded yet.'
        : 'No decision is in force. $gone';
  }
  final accepted = active
      .where((entry) => entry.status == DecisionStatus.accepted)
      .length;
  final proposed = active.length - accepted;
  return [
    '${active.length == 1 ? '1 decision is' : '${active.length} decisions are'}'
        ' in force ($accepted accepted, $proposed proposed)'
        '${proposed > 0 ? '; a proposed one binds only once the user '
                  'accepts it' : ''}.',
    ?gone,
  ].join(' ');
}

/// [topic] as a path from the project folder, when it is a path rather
/// than words; null when it is words. `outside` is set for an absolute
/// path that isn't below [projectRoot], and `path` is then the topic.
///
/// A path is an absolute path, or a topic without white space that has a
/// path separator or a file extension and, when [projectRoot] is known,
/// starts with a file or folder the project has.
({String path, bool outside})? _pathTopic(String topic, String? projectRoot) {
  final absolute =
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(topic) ||
      topic.startsWith('/') ||
      topic.startsWith(r'\\');
  if (absolute) {
    if (projectRoot == null) return (path: _posix(topic), outside: true);
    final relative = p.relative(topic, from: projectRoot);
    final outside = p.isAbsolute(relative) || p.split(relative).first == '..';
    return (path: _posix(outside ? topic : relative), outside: outside);
  }
  final looksLikeOne =
      !topic.contains(RegExp(r'\s')) &&
      (topic.contains('/') ||
          topic.contains(r'\') ||
          RegExp(r'\.[A-Za-z][A-Za-z0-9]*$').hasMatch(topic));
  if (!looksLikeOne) return null;
  final path = _posix(topic);
  if (projectRoot != null) {
    final first = p.join(projectRoot, path.split('/').first);
    if (FileSystemEntity.typeSync(first) == FileSystemEntityType.notFound) {
      return null;
    }
  }
  return (path: path, outside: false);
}

/// [path] with `/` separators, without a leading `./` or a trailing `/`.
String _posix(String path) {
  var posix = path.replaceAll(r'\', '/');
  while (posix.startsWith('./')) {
    posix = posix.substring(2);
  }
  return posix.length > 1 ? posix.replaceFirst(RegExp(r'/+$'), '') : posix;
}

/// Whether one of [record]'s path patterns covers [path]: the glob matches
/// it, or the pattern names it or a folder above it. A pattern that isn't
/// a valid glob covers nothing and is named in [problems].
bool _covers(DecisionRecord record, String path, List<String> problems) {
  var covers = false;
  for (final raw in record.paths) {
    final pattern = _posix(raw).replaceFirst(RegExp(r'/+$'), '');
    if (pattern == path || path.startsWith('$pattern/')) covers = true;
    try {
      final glob = Glob(pattern, context: p.posix);
      // A folder is covered when something in it would be.
      final folder = !RegExp(r'\.[A-Za-z0-9]+$').hasMatch(path);
      if (glob.matches(path) || (folder && glob.matches('$path/_'))) {
        covers = true;
      }
    } on FormatException {
      problems.add(
        'Decision ${record.numberText ?? record.file} has a path pattern '
        'that is not valid: `$raw`.',
      );
    }
  }
  return covers;
}

/// How well [record] matches [words]: per word the best of its number 5,
/// the title 3, a path 2 and the reason 1; then the sum.
int _score(DecisionRecord record, List<String> words) {
  final title = record.title.toLowerCase();
  final paths = [for (final path in record.paths) path.toLowerCase()];
  final why = record.why.toLowerCase();
  var total = 0;
  for (final word in words) {
    if (record.number != null && int.tryParse(word) == record.number) {
      total += 5;
    } else if (title.contains(word)) {
      total += 3;
    } else if (paths.any((path) => path.contains(word))) {
      total += 2;
    } else if (why.contains(word)) {
      total += 1;
    }
  }
  return total;
}
