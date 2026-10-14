import 'package:appstein_protocol/appstein_protocol.dart';

import '../deprecation_ignores.dart';
import '../verify_check.dart';

/// `dart.deprecated`: every use of a deprecated API is an error, wherever
/// it is in the project, in a fast run too (slice 1d.2, spec §9.1). It is
/// what lets `verify` check "zero deprecated-API findings in final code"
/// (spec §18).
///
/// It reports the uses the analyzer shows, and what tells the analyzer not
/// to show them:
///
/// - each diagnostic of the analyzer whose code is one of
///   `deprecatedUseCodes` (`deprecated_member_use`,
///   `deprecated_member_use_from_same_package`), with the analyzer's message
///   and code, whatever level the analyzer gave it;
/// - each `// ignore:` or `// ignore_for_file:` comment that names one of
///   those codes, on the comment's line, in the files the analysis server
///   analyzed. Such a comment can make the analyzer drop the diagnostic, so
///   it would otherwise be the cheapest way to "no deprecated APIs". It is
///   reported for naming the code, whether or not it hides a use where it
///   stands. The visible way out is a suppression with a reason (spec
///   §9.7);
/// - each such comment that says `type=hint`, which hides every hint,
///   deprecated use included, without naming it;
/// - each entry under `analyzer: errors:` of an `analysis_options.yaml`
///   the analysis covers that sets one of the two codes the analyzer accepts
///   there (`deprecated_member_use` and
///   `deprecated_member_use_from_same_package`) to `ignore` or `false`, on
///   the entry's line. When the project has no such file of its own, the
///   nearest one in a folder above it counts, with its path from the project
///   root (`../analysis_options.yaml`);
/// - each such entry in a file that one of those options files includes
///   (`include:` of a local file, followed through chains and lists), on the
///   included file's line, unless a file nearer to the project sets the code
///   back to `info`, `warning` or `error`. It is reported once, however
///   many options files include the file.
///
/// Not reported, by the owner's decision (2026-10-14): `// ignore:
/// type=lint`, which hides only the lint for the project's own deprecated
/// APIs and is common in generated files; a folder left out with
/// `analyzer: exclude:`; and a setting that comes in through an `include:`
/// of another package (`package:`), which is not followed (a known limit).
final class DartDeprecatedCheck implements GatheringCheck {
  /// Creates the check.
  const DartDeprecatedCheck();

  @override
  List<String> get ids => const ['dart.deprecated'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  // The comments are read from the source files: one that works removes
  // the diagnostic from the analysis server's reading. The server is asked
  // first, since its reading says which files to read.
  @override
  Future<void> gather(VerifyGathering gathering) async {
    await gathering.code();
    await gathering.deprecationIgnores();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async => [
    for (final diagnostic in context.code.diagnostics)
      if (isDeprecatedUseCode(diagnostic.code))
        Finding(
          id: 'dart.deprecated',
          severity: Severity.error,
          file: diagnostic.file,
          line: diagnostic.line,
          message: '${diagnostic.message} (`${diagnostic.code}`)',
          fixHint:
              'Replace it with the API the message names. `dart fix '
              '--dry-run` lists the uses it can migrate by itself.',
        ),
    for (final hiding in context.deprecationIgnores)
      Finding(
        id: 'dart.deprecated',
        severity: Severity.error,
        file: hiding.file,
        line: hiding.line,
        message: _message(hiding),
        fixHint: _fixHint(hiding),
      ),
  ];
}

/// What [hiding] is and what it tells the analyzer. Each sentence is true
/// whether or not the analyzer drops a diagnostic because of it, and
/// whether or not a deprecated API is used there: neither is known here.
String _message(DeprecationIgnore hiding) {
  if (hiding.optionsValue case final value?) {
    final where = hiding.includedBy.isEmpty
        ? 'the files this options file covers'
        : 'the files covered by the options files that include this file';
    return 'This entry sets ${_named(hiding.codes)} to `$value`: it tells '
        'the analyzer not to report the use of a deprecated API in $where.';
  }
  final comment = hiding.forFile ? '// ignore_for_file:' : '// ignore:';
  final where = hiding.forFile ? 'in this file' : 'on its line';
  if (hiding.allHints) {
    return 'This `$comment` comment says `type=hint`: it tells the analyzer '
        'to hide every hint $where, and the use of a deprecated API is a '
        'hint.';
  }
  final what = hiding.forFile
      ? 'every use of a deprecated API in this file'
      : 'the use of a deprecated API';
  return 'This `$comment` comment names ${_named(hiding.codes)}: it tells '
      'the analyzer to hide $what.';
}

/// The fix hint for [hiding]: the remedy and the visible way out. An entry
/// of an options file above the project (its file starts with `../`) has no
/// way out: a `suppressions:` path must stay inside the project, so none can
/// match it. Its hint offers the project's own options file instead.
///
/// - When an options file of the project already includes the file with the
///   entry, the hint says to set the code back to `info` there: the
///   including file's setting wins over the included one's.
/// - Otherwise the analyzer reads the project's own options file in place of
///   the one above, so the hint says to include the file above and set the
///   code back: an options file without the `include:` would drop every
///   shared rule with the entry.
String _fixHint(DeprecationIgnore hiding) {
  if (hiding.file.startsWith('../')) {
    final project = [
      for (final file in hiding.includedBy)
        if (!file.startsWith('../')) '`$file`',
    ];
    if (project.isNotEmpty) {
      final last = project.removeLast();
      final names = project.isEmpty ? last : '${project.join(', ')} and $last';
      return 'Remove the entry and replace the deprecated APIs. When that '
          'shared file has to stay as it is, set ${_named(hiding.codes)} back '
          'to `info` under `analyzer: errors:` in $names, which '
          '${project.isEmpty ? 'includes' : 'include'} it: the setting of the '
          'including file wins. A `suppressions:` path must be inside the '
          "project, so this finding can't be accepted there.";
    }
    return 'Remove the entry and replace the deprecated APIs. When that file '
        'is shared and has to stay as it is, give the project an '
        '`analysis_options.yaml` of its own that names the file above '
        'under `include:`, so its other rules still apply, and sets '
        '${_named(hiding.codes)} back to `info` under `analyzer: errors:`. '
        'An options file without that `include:` switches every rule of '
        'the file above off. A `suppressions:` path must be inside the '
        "project, so this finding can't be accepted there.";
  }
  return '${_remedy(hiding)} $_wayOut';
}

String _remedy(DeprecationIgnore hiding) {
  if (hiding.optionsValue != null) {
    return 'Remove the entry and replace the deprecated APIs.';
  }
  if (hiding.allHints) {
    return 'Name the hints to hide in place of `type=hint`, and replace '
        'any deprecated API.';
  }
  return 'Take the code out of the comment and replace the deprecated API.';
}

/// The visible way out (spec §9.7), which ends every fix hint here.
const _wayOut =
    'If it has to stay, accept the finding where it can be seen: a '
    '`suppressions:` entry for `dart.deprecated` with a `reason` in '
    '`appstein.yaml`.';

/// [codes] as a phrase: `` `a` ``, `` `a` and `b` `` or `` `a`, `b` and
/// `c` ``.
String _named(List<String> codes) {
  final quoted = [for (final code in codes) '`$code`'];
  if (quoted.length == 1) return quoted.single;
  final last = quoted.removeLast();
  return '${quoted.join(', ')} and $last';
}
