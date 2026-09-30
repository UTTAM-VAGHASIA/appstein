import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'guide_checker.dart';

/// Where Appstein's progress is recorded, relative to the repo root
/// (spec §19.6).
const progressFile = 'docs/superpowers/progress.yaml';

/// Where a slice stands, as `progress.yaml` records it.
enum SliceStatus {
  /// Finished: its pull request is open or merged.
  done,

  /// Being built, or the one to build next. At most one slice is next.
  next,

  /// Not started.
  planned,
}

/// How far a slice or milestone has got, counting its parts.
enum Stage {
  /// Every part is done.
  done,

  /// Some parts are done, and some aren't.
  underway,

  /// No part is done.
  planned,
}

/// The [Stage] of [parts]: done when every part is done, planned when none
/// is (or there are none), else underway.
Stage stageOf(Iterable<Slice> parts) {
  final all = parts.toList();
  final done = all.where((part) => part.status == SliceStatus.done).length;
  if (all.isNotEmpty && done == all.length) return Stage.done;
  return done == 0 ? Stage.planned : Stage.underway;
}

/// A slice of a milestone, or a sub-slice of a slice.
final class Slice {
  /// Creates a slice.
  const Slice({
    required this.id,
    required this.title,
    required this.summary,
    required this.line,
    this.status,
    this.plan,
    this.pr,
    this.finished,
    this.tooling = false,
    this.slices = const [],
  });

  /// The slice's ID, such as `1b` or `1b.2`.
  final String id;

  /// A short name.
  final String title;

  /// What the slice delivered, or will deliver. Text in backticks is shown
  /// as code.
  final String summary;

  /// The 1-based line of the slice's entry in `progress.yaml`.
  final int line;

  /// The slice's own status, or null for a slice that is only the sum of
  /// its [slices].
  final SliceStatus? status;

  /// The file name of the slice's plan in `docs/superpowers/plans/`.
  final String? plan;

  /// The number of the pull request that merged it.
  final int? pr;

  /// The day it was marked done, as `YYYY-MM-DD`.
  final String? finished;

  /// Whether it builds tooling for Appstein's own repo rather than the
  /// product.
  final bool tooling;

  /// Its sub-slices, in order.
  final List<Slice> slices;

  /// This slice, if it has a status of its own, and every such sub-slice
  /// below it, depth first.
  Iterable<Slice> get parts sync* {
    if (status != null) yield this;
    for (final slice in slices) {
      yield* slice.parts;
    }
  }

  /// The [parts] that build the product, or every part when all of them
  /// are tooling. A slice's progress bar counts these, so tooling doesn't
  /// make the product look further along.
  List<Slice> get productParts {
    final all = parts.toList();
    final product = all.where((part) => !part.tooling).toList();
    return product.isEmpty ? all : product;
  }

  /// How far the slice has got, counting every part.
  Stage get stage => stageOf(parts);
}

/// A milestone of the roadmap (spec §18).
final class Milestone {
  /// Creates a milestone.
  const Milestone({
    required this.id,
    required this.title,
    required this.summary,
    required this.line,
    this.slices = const [],
  });

  /// The milestone's ID, such as `M1`.
  final String id;

  /// A short name.
  final String title;

  /// What the milestone delivers, in a sentence.
  final String summary;

  /// The 1-based line of the milestone's entry in `progress.yaml`.
  final int line;

  /// Its slices, in order. Empty until the milestone has its own spec.
  final List<Slice> slices;

  /// How far the milestone has got, counting every part of every slice.
  Stage get stage => stageOf([for (final slice in slices) ...slice.parts]);
}

/// Everything `progress.yaml` records.
final class Progress {
  /// Creates the record.
  const Progress({required this.repository, required this.milestones});

  /// The repository's web address, without a trailing slash. A pull request
  /// links to `<repository>/pull/<number>`.
  final String repository;

  /// The milestones, in order.
  final List<Milestone> milestones;

  /// Every slice and sub-slice, depth first, in file order.
  Iterable<Slice> get allSlices sync* {
    for (final milestone in milestones) {
      for (final slice in milestone.slices) {
        yield* _walk(slice);
      }
    }
  }

  /// The slice marked next, if any.
  Slice? get next =>
      allSlices.where((slice) => slice.status == SliceStatus.next).firstOrNull;
}

Iterable<Slice> _walk(Slice slice) sync* {
  yield slice;
  for (final child in slice.slices) {
    yield* _walk(child);
  }
}

/// `progress.yaml` as read, and what is wrong with it.
final class ProgressRead {
  /// Creates the result.
  const ProgressRead(this.progress, this.problems);

  /// The record, or null when there are [problems].
  final Progress? progress;

  /// Everything wrong with the file, each with its line where it has one.
  final List<GuideProblem> problems;
}

/// Reads [progressFile] in [repoRoot]. A missing or unreadable file is a
/// problem.
ProgressRead readProgress(String repoRoot) {
  final file = File(p.join(repoRoot, progressFile));
  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException catch (error) {
    final message = file.existsSync()
        ? "Can't be read: ${error.osError?.message ?? error.message}."
        : 'Missing. It records where each milestone and slice stands '
              '(spec §19.6).';
    return ProgressRead(null, [GuideProblem(progressFile, null, message)]);
  }
  return parseProgress(text);
}

/// Parses the text of `progress.yaml` and checks every rule the file can
/// check on its own. A leading byte order mark is ignored. Every problem is
/// reported; the record is null when there is any.
ProgressRead parseProgress(String text) {
  final YamlNode root;
  try {
    root = loadYamlNode(text.startsWith('\uFEFF') ? text.substring(1) : text);
  } on YamlException catch (error) {
    final span = error.span;
    return ProgressRead(null, [
      GuideProblem(
        progressFile,
        span == null ? null : span.start.line + 1,
        'Not valid YAML: ${error.message}',
      ),
    ]);
  }
  final parser = _Parser();
  final progress = parser.progress(root);
  return parser.problems.isEmpty
      ? ProgressRead(progress, const [])
      : ProgressRead(null, parser.problems);
}

final _milestoneId = RegExp(r'^M[1-9][0-9]*$');
final _sliceId = RegExp(r'^[0-9]+[a-z]+(\.[0-9]+)*$');
final _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

const _fileKeys = {'repository', 'milestones'};
const _milestoneKeys = {'id', 'title', 'summary', 'slices'};
const _sliceKeys = {
  'id',
  'title',
  'summary',
  'status',
  'plan',
  'pr',
  'finished',
  'tooling',
  'slices',
};

/// Reads the YAML tree into the model, collecting every problem.
final class _Parser {
  final problems = <GuideProblem>[];
  final _ids = <String, int>{};

  void _problem(YamlNode node, String message) => problems.add(
    GuideProblem(progressFile, node.span.start.line + 1, message),
  );

  Progress? progress(YamlNode root) {
    final map = _map(root, 'The file');
    if (map == null) return null;
    _keys(map, 'The file', _fileKeys);
    final repository = _string(map, 'repository', 'The file');
    if (repository != null &&
        (!repository.startsWith('https://') || repository.endsWith('/'))) {
      _problem(
        map.nodes['repository']!,
        'repository must be an https:// address without a trailing slash, '
        'such as https://github.com/owner/repo.',
      );
    }
    final milestones = <Milestone>[
      for (final node in _list(map, 'milestones', 'The file', required: true))
        ?_milestone(node),
    ];
    final progress = Progress(
      repository: repository ?? '',
      milestones: milestones,
    );
    final next = [
      for (final slice in progress.allSlices)
        if (slice.status == SliceStatus.next) slice,
    ];
    if (next.length > 1) {
      problems.add(
        GuideProblem(
          progressFile,
          next[1].line,
          'More than one slice is next '
          '(${next.map((slice) => slice.id).join(', ')}). Only one slice can '
          'be next.',
        ),
      );
    }
    return progress;
  }

  Milestone? _milestone(YamlNode node) {
    final map = _map(node, 'A milestone');
    if (map == null) return null;
    final id = _string(map, 'id', 'A milestone');
    final what = id == null ? 'A milestone' : 'Milestone $id';
    _keys(map, what, _milestoneKeys);
    if (id != null) {
      final idNode = map.nodes['id']!;
      if (!_milestoneId.hasMatch(id)) {
        _problem(idNode, '$what: id must look like M1.');
      }
      _unique(id, idNode);
    }
    final title = _string(map, 'title', what);
    final summary = _string(map, 'summary', what);
    final slices = <Slice>[
      for (final child in _list(map, 'slices', what))
        ?_slice(child, parent: null),
    ];
    if (id == null || title == null || summary == null) return null;
    return Milestone(
      id: id,
      title: title,
      summary: summary,
      line: node.span.start.line + 1,
      slices: slices,
    );
  }

  Slice? _slice(YamlNode node, {required String? parent}) {
    final map = _map(node, 'A slice');
    if (map == null) return null;
    final id = _string(map, 'id', 'A slice');
    final what = id == null ? 'A slice' : 'Slice $id';
    _keys(map, what, _sliceKeys);
    if (id != null) {
      final idNode = map.nodes['id']!;
      if (!_sliceId.hasMatch(id)) {
        _problem(idNode, '$what: id must look like 1a or 1a.1.');
      } else if (parent != null && !id.startsWith('$parent.')) {
        _problem(
          idNode,
          '$what: a sub-slice of $parent needs an id starting with $parent.',
        );
      }
      _unique(id, idNode);
    }
    final title = _string(map, 'title', what);
    final summary = _string(map, 'summary', what);
    final statusText = _string(map, 'status', what, required: false);
    SliceStatus? status;
    if (statusText != null) {
      status = SliceStatus.values
          .where((value) => value.name == statusText)
          .firstOrNull;
      if (status == null) {
        _problem(
          map.nodes['status']!,
          '$what: status must be done, next or planned, not $statusText.',
        );
      }
    }
    final plan = _string(map, 'plan', what, required: false);
    if (plan != null &&
        (plan.contains('/') || plan.contains(r'\') || !plan.endsWith('.md'))) {
      _problem(
        map.nodes['plan']!,
        '$what: plan must be a file name in docs/superpowers/plans/, such as '
        '2026-09-29-slice-1a-workspace-cli-doctor.md.',
      );
    }
    final pr = _positiveInt(map, 'pr', what);
    final finished = _date(map, 'finished', what);
    final tooling = _bool(map, 'tooling', what);
    final children = <Slice>[
      for (final child in _list(map, 'slices', what))
        ?_slice(child, parent: id),
    ];
    if (statusText == null && children.isEmpty) {
      _problem(
        map,
        '$what needs a status (done, next or planned), or sub-slices.',
      );
    }
    if (status == SliceStatus.done) {
      final missing = [
        if (map.nodes['plan'] == null) 'plan',
        if (map.nodes['pr'] == null) 'pr',
        if (map.nodes['finished'] == null) 'finished',
      ];
      if (missing.isNotEmpty) {
        _problem(map, '$what is done, so it needs ${_and(missing)}.');
      }
    } else if (status != null) {
      for (final key in const ['pr', 'finished']) {
        final value = map.nodes[key];
        if (value != null) {
          _problem(value, '$what: $key is only for a done slice.');
        }
      }
    }
    if (id == null || title == null || summary == null) return null;
    return Slice(
      id: id,
      title: title,
      summary: summary,
      line: node.span.start.line + 1,
      status: status,
      plan: plan,
      pr: pr,
      finished: finished,
      tooling: tooling,
      slices: children,
    );
  }

  YamlMap? _map(YamlNode node, String what) {
    if (node is YamlMap) return node;
    _problem(node, '$what must be a map.');
    return null;
  }

  /// Reports every key of [map] that isn't one of [keys]. Called once the
  /// entry's ID is known, so the problem can name the entry.
  void _keys(YamlMap map, String what, Set<String> keys) {
    final known = (keys.toList()..sort()).join(', ');
    for (final key in map.nodes.keys) {
      final name = key is YamlScalar ? '${key.value}' : '$key';
      if (!keys.contains(name)) {
        _problem(
          key is YamlNode ? key : map,
          '$what has an unknown key: $name. Known: $known.',
        );
      }
    }
  }

  String? _string(
    YamlMap map,
    String key,
    String what, {
    bool required = true,
  }) {
    final node = map.nodes[key];
    if (node == null) {
      if (required) _problem(map, '$what needs $key.');
      return null;
    }
    final value = node.value;
    if (value is! String || value.trim().isEmpty) {
      _problem(node, '$what: $key must be text.');
      return null;
    }
    return value.trim();
  }

  List<YamlNode> _list(
    YamlMap map,
    String key,
    String what, {
    bool required = false,
  }) {
    final node = map.nodes[key];
    if (node == null) {
      if (required) _problem(map, '$what needs $key.');
      return const [];
    }
    if (node is! YamlList || (required && node.nodes.isEmpty)) {
      _problem(
        node,
        '$what: $key must be a list'
        '${required ? ' with at least one entry' : ''}.',
      );
      return const [];
    }
    return node.nodes;
  }

  int? _positiveInt(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return null;
    final value = node.value;
    if (value is int && value > 0) return value;
    _problem(node, '$what: $key must be a whole number above 0.');
    return null;
  }

  String? _date(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return null;
    final value = '${node.value}';
    final match = _day.firstMatch(value);
    if (match != null) {
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final date = DateTime.utc(year, month, day);
      if (date.year == year && date.month == month && date.day == day) {
        return value;
      }
    }
    _problem(node, '$what: $key must be a date like 2026-10-01, not $value.');
    return null;
  }

  bool _bool(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return false;
    final value = node.value;
    if (value is bool) return value;
    _problem(node, '$what: $key must be true or false.');
    return false;
  }

  void _unique(String id, YamlNode node) {
    final first = _ids[id];
    if (first == null) {
      _ids[id] = node.span.start.line + 1;
    } else {
      _problem(
        node,
        '$id is used twice (first on line $first). IDs must be '
        'unique.',
      );
    }
  }
}

String _and(List<String> items) => items.length == 1
    ? items.single
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
