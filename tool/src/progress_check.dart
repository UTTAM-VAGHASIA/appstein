import 'dart:io';

import 'package:path/path.dart' as p;

import 'guide_checker.dart';
import 'markdown.dart';
import 'progress.dart';

/// The design spec, whose §18 lists the milestones and each milestone's
/// slices.
const specFile = 'docs/superpowers/specs/2026-09-29-appstein-design.md';

/// The folder of slice plans, one Markdown file per slice.
const plansFolder = 'docs/superpowers/plans';

final _notes = RegExp(r'^## Notes from execution\b');

/// Whether [text] has a `## Notes from execution` heading outside code
/// fences.
bool _hasNotes(String text) {
  final fences = FenceTracker();
  for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
    if (fences.next(line) == FenceLine.prose && _notes.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

/// Checks [progress] against the repo at [repoRoot] (spec §19.6):
/// - every plan in [plansFolder] (a `.md` file directly in it) is named by
///   exactly one slice, and every plan a slice names exists;
/// - a slice whose plan has a `## Notes from execution` heading is done;
/// - the milestones match spec §18, and so do the slices of each milestone
///   §18 has a table for.
List<GuideProblem> checkProgress(String repoRoot, Progress progress) => [
  ..._checkPlans(repoRoot, progress),
  ..._checkSpec(repoRoot, progress),
];

/// Checks that every `merge` commit in [progress] is in the repo, using
/// [hasCommit] (spec §19.6). A mistyped ID would link the visual page to a
/// commit that doesn't exist. Slices with a `pr` aren't looked up.
List<GuideProblem> checkMerges(
  Progress progress,
  bool Function(String rev) hasCommit,
) => [
  for (final slice in progress.allSlices)
    if (slice.merge case final merge? when !hasCommit(merge))
      GuideProblem(
        progressFile,
        slice.line,
        'Slice ${slice.id}: merge $merge is not a commit in this repo. A '
        'shallow clone lacks old commits; run git fetch --unshallow.',
      ),
];

List<GuideProblem> _checkPlans(String repoRoot, Progress progress) {
  final problems = <GuideProblem>[];
  final owners = <String, List<Slice>>{};
  for (final slice in progress.allSlices) {
    final plan = slice.plan;
    if (plan != null) owners.putIfAbsent(plan, () => []).add(slice);
  }
  final folder = Directory(p.join(repoRoot, plansFolder));
  final plans = <String>[
    if (folder.existsSync())
      for (final entry in folder.listSync())
        if (entry is File && entry.path.endsWith('.md')) p.basename(entry.path),
  ]..sort();
  for (final plan in plans) {
    final slices = owners[plan] ?? const <Slice>[];
    if (slices.isEmpty) {
      problems.add(
        GuideProblem(
          '$plansFolder/$plan',
          null,
          'No slice in $progressFile names this plan. Set it as the plan of '
              'the slice it builds.',
        ),
      );
      continue;
    }
    if (slices.length > 1) {
      problems.add(
        GuideProblem(
          progressFile,
          slices[1].line,
          'Slices ${slices.map((slice) => slice.id).join(' and ')} both name '
          'the plan $plan. A plan belongs to one slice.',
        ),
      );
    }
    final String text;
    try {
      text = File(p.join(folder.path, plan)).readAsStringSync();
    } on FileSystemException {
      problems.add(
        GuideProblem(
          '$plansFolder/$plan',
          null,
          "Can't be read, so its notes from execution can't be checked.",
        ),
      );
      continue;
    }
    if (!_hasNotes(text)) continue;
    for (final slice in slices) {
      if (slice.status != SliceStatus.done) {
        problems.add(
          GuideProblem(
            progressFile,
            slice.line,
            "Slice ${slice.id}'s plan has notes from execution, so the slice "
            'is finished. Mark it done, with its pr and finished date.',
          ),
        );
      }
    }
  }
  for (final entry in owners.entries) {
    if (plans.contains(entry.key)) continue;
    for (final slice in entry.value) {
      problems.add(
        GuideProblem(
          progressFile,
          slice.line,
          'Slice ${slice.id} names the plan ${entry.key}, which is not in '
          '$plansFolder/.',
        ),
      );
    }
  }
  return problems;
}

List<GuideProblem> _checkSpec(String repoRoot, Progress progress) {
  final String text;
  try {
    text = File(p.join(repoRoot, specFile)).readAsStringSync();
  } on FileSystemException {
    return const [
      GuideProblem(
        specFile,
        null,
        "Can't be read, so progress can't be checked against §18.",
      ),
    ];
  }
  final spec = specMilestones(text);
  if (spec == null) {
    return const [
      GuideProblem(
        specFile,
        null,
        'Has no "## 18. Milestones" section, so progress can\'t be checked '
        'against it.',
      ),
    ];
  }
  final recorded = {
    for (final milestone in progress.milestones) milestone.id: milestone,
  };
  return [
    ..._compare('milestone', spec.milestones, recorded.keys.toList()),
    for (final entry in spec.slices.entries)
      if (recorded[entry.key] case final milestone?)
        ..._compare('${entry.key} slice', entry.value, [
          for (final slice in milestone.slices) slice.id,
        ]),
  ];
}

List<GuideProblem> _compare(
  String kind,
  List<String> inSpec,
  List<String> recorded,
) => [
  for (final id in inSpec)
    if (!recorded.contains(id))
      GuideProblem(
        progressFile,
        null,
        'Spec §18 has the $kind $id, but $progressFile does not. Add it.',
      ),
  for (final id in recorded)
    if (!inSpec.contains(id))
      GuideProblem(
        progressFile,
        null,
        '$progressFile has the $kind $id, but spec §18 does not. Remove it, '
        'or add it to the spec first.',
      ),
];

final _section18 = RegExp(r'^## 18\. ');
final _milestoneHeading = RegExp(r'^### (M\d+):');
final _laterMilestone = RegExp(r'^- \*\*(M\d+):');
final _sliceRow = RegExp(r'^\| \*\*([0-9a-z.]+)\*\* \|');

/// The milestones spec §18 names, in order, and the slices each milestone's
/// table lists, in order. A milestone with a `### M<n>:` heading owns the
/// `| **<id>** |` table rows below it; one named only in a `- **M<n>:`
/// bullet has no slices yet. Null when the spec has no `## 18.` section.
({List<String> milestones, Map<String, List<String>> slices})? specMilestones(
  String spec,
) {
  final lines = spec.replaceAll('\r\n', '\n').split('\n');
  final start = lines.indexWhere(_section18.hasMatch);
  if (start < 0) return null;
  final milestones = <String>[];
  final slices = <String, List<String>>{};
  String? current;
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('## ')) break;
    final heading = _milestoneHeading.firstMatch(line);
    if (heading != null) {
      current = heading[1]!;
      milestones.add(current);
      slices[current] = [];
      continue;
    }
    if (line.startsWith('### ')) {
      current = null;
      continue;
    }
    final later = _laterMilestone.firstMatch(line);
    if (later != null) {
      milestones.add(later[1]!);
      continue;
    }
    final row = _sliceRow.firstMatch(line);
    if (row != null && current != null) slices[current]!.add(row[1]!);
  }
  return (milestones: milestones, slices: slices);
}
