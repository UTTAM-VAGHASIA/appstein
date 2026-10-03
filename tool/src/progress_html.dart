import 'progress.dart';

/// The generated sections of the spec's visual page that show progress
/// (spec §19.6), by section name: `progress-status`, a pill at the top of
/// the page, and `progress`, the milestone rail with each milestone's slice
/// bar and timeline. The page's own CSS styles the `pg-*` classes.
Map<String, String> renderProgressSections(Progress progress) => {
  'progress-status': renderProgressStatus(progress),
  'progress': renderProgress(progress),
};

/// A pill naming the milestone being built and the slice that is next,
/// linking to the progress section.
String renderProgressStatus(Progress progress) {
  final current = progress.milestones
      .where((milestone) => milestone.stage != Stage.done)
      .firstOrNull;
  final next = progress.next;
  final String text;
  if (current == null) {
    text = 'Every milestone is done';
  } else {
    final verb = current.stage == Stage.underway ? 'Building' : 'Starting';
    final lead = '$verb ${_escape(current.id)}';
    text = next == null
        ? lead
        : '$lead · next: <b>${_escape(next.id)}</b> ${_escape(next.title)}';
  }
  return '<a class="pill pg-status" href="#progress"><span class="dot" '
      'aria-hidden="true"></span>$text</a>';
}

/// The milestone rail, then for each milestone with slices its bar (one
/// segment per slice, filled by the share of its product parts that are
/// done) and its timeline of slices and sub-slices. Pull requests and merge
/// commits link to the repository; plans link relative to
/// `docs/superpowers/specs/`.
String renderProgress(Progress progress) {
  final out = <String>['<ol class="pg-rail" aria-label="Milestones">'];
  for (final milestone in progress.milestones) {
    out.add(
      '  <li class="pg-${milestone.stage.name}" '
      'title="${_escape(milestone.summary.replaceAll('`', ''))}"><b>${_escape(milestone.id)}</b>'
      '<span>${_escape(milestone.title)}</span>'
      '<em>${_stageLabel(milestone.stage)}</em></li>',
    );
  }
  out.add('</ol>');
  for (final milestone in progress.milestones) {
    if (milestone.slices.isEmpty) continue;
    out
      ..add('<div class="pg-milestone">')
      ..add('  <h3>${_escape(milestone.id)} slices</h3>')
      ..add('  <div class="pg-bar">');
    for (final slice in milestone.slices) {
      final parts = slice.productParts;
      final done = parts
          .where((part) => part.status == SliceStatus.done)
          .length;
      final fill = parts.isEmpty ? 0 : (done * 100 / parts.length).round();
      out.add(
        '    <a class="pg-seg pg-${_state(slice)}" href="#${_anchor(slice)}" '
        'style="--fill:$fill%"><b>${_escape(slice.id)}</b>'
        '<span>${_escape(slice.title)}</span>'
        '<i>$done of ${parts.length} done</i></a>',
      );
    }
    out
      ..add('  </div>')
      ..add('  <ol class="pg-timeline">');
    for (final slice in milestone.slices) {
      _item(progress, slice, out, '    ');
    }
    out
      ..add('  </ol>')
      ..add('</div>');
  }
  return out.join('\n');
}

void _item(Progress progress, Slice slice, List<String> out, String indent) {
  final state = _state(slice);
  final tooling = slice.tooling
      ? ' <span class="tag neutral">Repo tooling</span>'
      : '';
  out
    ..add('$indent<li class="pg-item pg-$state" id="${_anchor(slice)}">')
    ..add(
      '$indent  <p class="pg-title"><b>${_escape(slice.id)}</b> '
      '${_escape(slice.title)} ${_badge(state)}$tooling</p>',
    )
    ..add('$indent  <p class="pg-summary">${_inline(slice.summary)}</p>');
  final finished = slice.finished;
  final pr = slice.pr;
  final merge = slice.merge;
  final plan = slice.plan;
  final meta = [
    if (finished != null)
      '<time datetime="$finished">${_longDate(finished)}</time>',
    if (pr != null)
      '<a href="${_escape(progress.repository)}/pull/$pr">PR #$pr</a>',
    if (merge != null)
      '<a href="${_escape(progress.repository)}/commit/$merge">merged in '
          '<code>$merge</code></a>',
    if (plan != null)
      '<a href="../plans/${_escape(Uri.encodeComponent(plan))}">Plan</a>',
  ];
  if (meta.isNotEmpty) {
    out.add('$indent  <p class="pg-meta">${meta.join(' · ')}</p>');
  }
  if (slice.slices.isNotEmpty) {
    out.add('$indent  <ol class="pg-timeline pg-sub">');
    for (final child in slice.slices) {
      _item(progress, child, out, '$indent    ');
    }
    out.add('$indent  </ol>');
  }
  out.add('$indent</li>');
}

/// `done`, `next` or `planned` for a slice with a status of its own, else
/// its stage: `done`, `underway` or `planned`.
String _state(Slice slice) => slice.status?.name ?? slice.stage.name;

String _anchor(Slice slice) => 'pg-${slice.id.replaceAll('.', '-')}';

String _badge(String state) => switch (state) {
  'done' => '<span class="tag ok">Done</span>',
  'next' => '<span class="tag info">Next</span>',
  'underway' => '<span class="tag warn">In progress</span>',
  _ => '<span class="tag neutral">Planned</span>',
};

String _stageLabel(Stage stage) => switch (stage) {
  Stage.done => 'Done',
  Stage.underway => 'In progress',
  Stage.planned => 'Planned',
};

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `2026-09-30` as `30 Sep 2026`. The parser only lets real dates through.
String _longDate(String day) {
  final parts = day.split('-');
  return '${int.parse(parts[2])} ${_months[int.parse(parts[1]) - 1]} '
      '${parts[0]}';
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// [text] escaped, with each `` `code` `` span shown as code.
String _inline(String text) => _escape(
  text,
).replaceAllMapped(RegExp('`([^`]+)`'), (match) => '<code>${match[1]}</code>');
