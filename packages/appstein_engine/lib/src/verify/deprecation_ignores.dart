// What the analyzer takes for an `// ignore:` comment, and which names it
// reads from one, is a rule it keeps in its `src/` folder with no public
// way to ask (`ignore_info.dart`). This file uses that code, so a comment
// in a string, a block comment or a doc comment's code sample is told from
// a real one the way the analyzer tells them.
//
// It is the rule of the `analyzer` package the engine pins in pubspec.yaml,
// not of the analyzer in the project's own SDK, which answers the analysis
// server. The two can differ after an SDK upgrade;
// deprecation_ignores_test.dart holds the cases compared with the pinned
// SDK, and fails when an upgrade of the package changes the rule.
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/src/ignore_comments/ignore_info.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The two names the analyzer accepts under `analyzer: errors:` of an
/// `analysis_options.yaml`, in lower case. It warns `unrecognized_error_code`
/// about the other five of [deprecatedUseCodes] and still reports the
/// diagnostic, so an entry under one of those hides nothing (every name
/// compared with `dart analyze` of the pinned SDK, 3.13.4, on 2026-10-14).
const _optionsCodes = {
  'deprecated_member_use',
  'deprecated_member_use_from_same_package',
};

/// The names the analyzer has for the use of a deprecated API, in lower
/// case: each is a diagnostic's code, or a name an `// ignore:` comment may
/// give to hide one form of it.
///
/// - The first four are the analyzer's own `deprecated_member_use` and the
///   longer names of its forms, read from the pinned `analyzer` package
///   (`diagnosticCodeValues`); a test fails when an upgrade adds or removes
///   one.
/// - The last three are the lint `deprecated_member_use_from_same_package`
///   and the longer names of its two forms. The lint lives in the Dart SDK,
///   not in a package, so these were established by running the pinned
///   SDK's analyzer (3.13.4, 2026-10-14); a test with a real analysis
///   server fails when one of them stops hiding the lint.
const deprecatedUseCodes = {
  'deprecated_member_use',
  'deprecated_member_use_with_message',
  'deprecated_member_use_implicit',
  'deprecated_member_use_implicit_with_message',
  'deprecated_member_use_from_same_package',
  'deprecated_member_use_from_same_package_with_message',
  'deprecated_member_use_from_same_package_without_message',
};

/// Whether [code], an analyzer diagnostic's code or a name in an
/// `// ignore:` comment, is one of [deprecatedUseCodes]. Letter case
/// doesn't count, as it doesn't for the analyzer. A name that only starts
/// like one, such as `deprecated_member_use_foo`, is not one.
bool isDeprecatedUseCode(String code) =>
    deprecatedUseCodes.contains(code.toLowerCase());

/// One place in a project's files that tells the analyzer not to report the
/// use of a deprecated API. It is one of three things:
///
/// - an `// ignore:` or `// ignore_for_file:` comment in a Dart file that
///   names a deprecated-use diagnostic ([isDeprecatedUseCode]): [codes] has
///   the names;
/// - such a comment that says `type=hint`, which hides every hint, the
///   analyzer's `deprecated_member_use` among them: [allHints] is true and
///   [codes] is empty. (`type=lint` is not one: it hides only the lint for
///   the project's own deprecated APIs, which a project chooses to have.);
/// - an entry under `analyzer: errors:` in an `analysis_options.yaml` that
///   sets a deprecated-use diagnostic to `ignore` or `false`:
///   [optionsValue] is the value and [codes] the one name.
///
/// Whether the analyzer drops a diagnostic because of it is not known here:
/// a comment that names the wrong form for the use below it, or stands too
/// far above it, hides nothing and is still one of these.
final class DeprecationIgnore {
  /// Creates one.
  const DeprecationIgnore({
    required this.file,
    required this.line,
    required this.forFile,
    required this.codes,
    this.allHints = false,
    this.optionsValue,
    this.includedBy = const [],
  });

  /// The file it is in, from the project root, with `/` on every system.
  final String file;

  /// The 1-based line the comment, or the entry's name, is on.
  final int line;

  /// Whether it is an `// ignore_for_file:` comment, which is about the
  /// whole file. An `// ignore:` comment is about one line. False for an
  /// entry of `analysis_options.yaml`.
  final bool forFile;

  /// The deprecated-use codes it names, in lower case, in the order
  /// written, each once. Empty for a `type=hint` comment.
  final List<String> codes;

  /// Whether it is a comment that says `type=hint`.
  final bool allHints;

  /// For an entry of `analysis_options.yaml`: the value it gives the code,
  /// as written, such as `ignore`. Null for a comment.
  final String? optionsValue;

  /// For an entry the analyzer reads through an `include:`: the options files
  /// that include its file and so apply it, from the project root with `/`
  /// (such as `analysis_options.yaml`), sorted, each once. Empty for an entry
  /// in an options file the analysis covers, and for a comment.
  final List<String> includedBy;
}

final _typeHint = RegExp(r'type\s*=\s*hint');

/// The comments in the Dart source [content] that name a deprecated-use
/// diagnostic or say `type=hint`, in line order, each as a comment of
/// [file]. A comment that does both is there twice, once for each.
///
/// Only what the pinned `analyzer` package takes for an `// ignore:` or
/// `// ignore_for_file:` comment counts, so text that looks like one inside
/// a string, a block comment or the code sample of a doc comment never
/// does. A name with a plugin before it (`some_plugin/deprecated_member_use`)
/// counts too. [content] need not be valid Dart.
List<DeprecationIgnore> deprecationIgnoresIn(
  String content, {
  required String file,
}) {
  // Most files have neither: they are not parsed at all.
  final lower = content.toLowerCase();
  if (!lower.contains('deprecated_member_use') && !_typeHint.hasMatch(lower)) {
    return const [];
  }
  final unit = parseString(content: content, throwIfDiagnostics: false).unit;
  final found = <DeprecationIgnore>[];
  for (final comment in unit.ignoreComments) {
    final elements = comment.ignoredElements;
    final codes = <String>{
      for (final element in elements)
        if (element is IgnoredDiagnosticName &&
            isDeprecatedUseCode(element.name))
          element.name,
    };
    final allHints = elements.any(
      (element) => element is IgnoredDiagnosticType && element.type == 'hint',
    );
    final line = unit.lineInfo.getLocation(comment.offset).lineNumber;
    final forFile = IgnoreInfo.isIgnoreForFileComment(comment.lexeme);
    if (codes.isNotEmpty) {
      found.add(
        DeprecationIgnore(
          file: file,
          line: line,
          forFile: forFile,
          codes: List.unmodifiable(codes),
        ),
      );
    }
    if (allHints) {
      found.add(
        DeprecationIgnore(
          file: file,
          line: line,
          forFile: forFile,
          codes: const [],
          allHints: true,
        ),
      );
    }
  }
  // Stable: a comment's two entries keep their order.
  return [
    for (final (_, entry)
        in found.indexed.toList()..sort((a, b) {
          final byLine = a.$2.line.compareTo(b.$2.line);
          return byLine != 0 ? byLine : a.$1.compareTo(b.$1);
        }))
      entry,
  ];
}

/// The entries of the `analysis_options.yaml` text [content] that switch a
/// deprecated-use diagnostic off, in line order, each as an entry of
/// [file]: a name under `analyzer: errors:` that the analyzer accepts there
/// (`deprecated_member_use` and `deprecated_member_use_from_same_package`,
/// in any letter case), with a value the analyzer reads as "ignore". Those
/// are `ignore` and `false`, in any letter case (its own list, compared with
/// the pinned SDK on 2026-10-14); `info`, `warning` and `error` keep the
/// diagnostic. The longer names of [deprecatedUseCodes] are for an
/// `// ignore:` comment only: the analyzer rejects them here and an entry
/// under one hides nothing, so it is not one.
///
/// Only the entries of [content] itself: what comes in through its
/// `include:` is read by [readDeprecationIgnores]. A text that isn't YAML,
/// or has another shape, gives nothing.
List<DeprecationIgnore> deprecationSwitchesIn(
  String content, {
  required String file,
}) {
  if (!content.toLowerCase().contains('deprecated_member_use')) {
    return const [];
  }
  return [
    for (final setting in _parseOptions(content).settings)
      if (setting.off) setting.toIgnore(file),
  ]..sort((a, b) => a.line.compareTo(b.line));
}

/// What an `analysis_options.yaml` text says that matters here: the files it
/// includes and, in the order written, the entries under `analyzer: errors:`
/// that give one of the two deprecated-use codes a value the analyzer acts
/// on.
final class _Options {
  const _Options(this.includes, this.settings);

  /// What `include:` names, in the order written: one string, or each string
  /// of a list. The text of each, not yet resolved.
  final List<String> includes;

  /// The entries for [_optionsCodes] that either switch the diagnostic off
  /// (`ignore`, `false`) or set it to a severity (`info`, `warning`,
  /// `error`), each in any letter case. A value the analyzer does not act on
  /// (`true`, an unknown word, none) leaves out its entry.
  final List<_Setting> settings;
}

/// One entry of [_Options.settings].
final class _Setting {
  const _Setting({
    required this.code,
    required this.line,
    required this.written,
    required this.off,
  });

  /// The name of the code, in lower case.
  final String code;

  /// The 1-based line of the entry's name.
  final int line;

  /// The value as written.
  final String written;

  /// Whether the value switches the diagnostic off.
  final bool off;

  /// This entry as an entry of [file].
  DeprecationIgnore toIgnore(
    String file, {
    List<String> includedBy = const [],
  }) => DeprecationIgnore(
    file: file,
    line: line,
    forFile: false,
    codes: List.unmodifiable([code]),
    optionsValue: written,
    includedBy: includedBy,
  );
}

/// Reads [content] as an `analysis_options.yaml`. A text that isn't YAML, or
/// has another shape, has nothing in it.
_Options _parseOptions(String content) {
  const none = _Options([], []);
  final YamlNode root;
  try {
    root = loadYamlNode(content);
  } on YamlException {
    return none;
  }
  if (root is! YamlMap) return none;
  final include = root.nodes['include'];
  final includes = switch (include) {
    YamlScalar(value: final String text) => [text],
    YamlList() => [
      for (final item in include.nodes)
        if (item is YamlScalar && item.value is String) item.value as String,
    ],
    _ => <String>[],
  };
  final analyzer = root.nodes['analyzer'];
  final errors = analyzer is YamlMap ? analyzer.nodes['errors'] : null;
  final settings = <_Setting>[];
  if (errors is YamlMap) {
    for (final MapEntry(:key, :value) in errors.nodes.entries) {
      if (key is! YamlScalar || value is! YamlScalar) continue;
      final name = key.value;
      if (name is! String || !_optionsCodes.contains(name.toLowerCase())) {
        continue;
      }
      final written = '${value.value}';
      final off = const {'ignore', 'false'}.contains(written.toLowerCase());
      if (!off &&
          !const {'info', 'warning', 'error'}.contains(written.toLowerCase())) {
        continue;
      }
      settings.add(
        _Setting(
          code: name.toLowerCase(),
          line: key.span.start.line + 1,
          written: written,
          off: off,
        ),
      );
    }
  }
  return _Options(includes, settings);
}

/// What tells the analyzer not to report deprecated use in [files] of the
/// project at [projectRoot], in file and line order: the comments
/// ([deprecationIgnoresIn]) and the `analysis_options.yaml` entries
/// ([deprecationSwitchesIn]). [files] are paths from the project root with
/// `/`: the files the analysis server analyzed
/// (`CodeReading.analyzedFiles`), so exactly the analyzer's files are read,
/// a part file whose name doesn't end in `.dart` and every
/// `analysis_options.yaml` the analysis covers included.
///
/// - Any other `.yaml` file and an `.xml` file is skipped: the analyzer
///   reads those as something other than Dart (`pubspec.yaml`,
///   `AndroidManifest.xml`).
/// - When the project root has no `analysis_options.yaml` of its own, the
///   analyzer applies the nearest one in a folder above it, which no file of
///   [files] is. That one is read for its entries too, and its `file` is
///   its path from the project root, such as `../analysis_options.yaml`
///   (still with `/`): no `suppressions:` path can match it, since those
///   must stay inside the project. A root with an options file of its own
///   has the analyzer look no further up, so none above it is read.
/// - An `include:` of a local file is followed, from each options file the
///   analyzer applies (those of [files] and the one above the project). A
///   switch-off in an included file is an entry of that file, with its path
///   from the project root, whether it is inside the project or above it
///   (`../base_options.yaml`), and [DeprecationIgnore.includedBy] names the
///   options files that include it. It is there only when it is still in
///   force after the merge: an entry of a file nearer to the project (the
///   including file itself first) that sets the code to `info`, `warning` or
///   `error` takes it back, and one that switches it off too is the entry
///   reported in its place. An include of a `package:` URI is not followed,
///   and a file that is missing, can't be read or isn't YAML adds nothing.
/// - It reads the files a few at a time without blocking, and never writes
///   one. The files an `include:` leads to are read one at a time, each
///   once.
/// - A file that can't be read, or is gone, is left out. The analysis
///   server reports no diagnostic for a file it can't read either (seen on
///   Windows with a file another process holds locked), so the comment and
///   the use it hides go unreported together.
Future<List<DeprecationIgnore>> readDeprecationIgnores(
  String projectRoot,
  Iterable<String> files,
) async {
  bool isOptions(String file) => p.url.basename(file) == _optionsName;
  final sources = [
    for (final file in files.toSet())
      if (isOptions(file) ||
          !_notDart.contains(p.url.extension(file).toLowerCase()))
        file,
  ]..sort();
  final found = <DeprecationIgnore>[];
  // The options files the analyzer applies, read: the walk through their
  // `include:` starts from each.
  final applied = <(String, String)>[];
  final enclosing = await _enclosingOptions(projectRoot);
  if (enclosing != null) {
    final content = await _read(enclosing);
    if (content != null) {
      applied.add((enclosing, content));
      found.addAll(
        deprecationSwitchesIn(content, file: _fromRoot(projectRoot, enclosing)),
      );
    }
  }
  for (var start = 0; start < sources.length; start += _readAtOnce) {
    final batch = sources.skip(start).take(_readAtOnce).toList();
    final contents = await Future.wait([
      for (final file in batch)
        _read(p.joinAll([projectRoot, ...file.split('/')])),
    ]);
    for (final (index, content) in contents.indexed) {
      if (content == null) continue;
      final file = batch[index];
      if (isOptions(file)) {
        applied.add((p.joinAll([projectRoot, ...file.split('/')]), content));
        found.addAll(deprecationSwitchesIn(content, file: file));
      } else {
        found.addAll(deprecationIgnoresIn(content, file: file));
      }
    }
  }
  found.addAll(await _includedEntries(projectRoot, applied));
  // Stable: the entries of one file keep the order they were found in.
  return [
    for (final (_, entry)
        in found.indexed.toList()..sort((a, b) {
          final byFile = a.$2.file.compareTo(b.$2.file);
          if (byFile != 0) return byFile;
          final byLine = a.$2.line.compareTo(b.$2.line);
          return byLine != 0 ? byLine : a.$1.compareTo(b.$1);
        }))
      entry,
  ];
}

/// [path], a file, from [projectRoot] with `/` on every system.
String _fromRoot(String projectRoot, String path) {
  final relative = p.relative(path, from: p.absolute(projectRoot));
  return p.isAbsolute(relative)
      ? relative.replaceAll(r'\', '/')
      : p.posix.joinAll(p.split(relative));
}

/// The deprecated-use entries that [applied], the options files the analyzer
/// applies as `(path, text)`, take in through `include:`: those left
/// switched off once the files are merged as the analyzer merges them. An
/// entry of an applied file itself is not among them: the caller has it.
///
/// An entry reached by several of the files is there once, naming them all
/// in [DeprecationIgnore.includedBy].
Future<List<DeprecationIgnore>> _includedEntries(
  String projectRoot,
  List<(String, String)> applied,
) async {
  if (applied.isEmpty) return const [];
  final walker = _IncludeWalker();
  final own = <String>{};
  for (final (path, content) in applied) {
    walker.seed(path, content);
  }
  for (final (path, _) in applied) {
    final options = await walker.options(path);
    for (final setting in options?.settings ?? const <_Setting>[]) {
      if (setting.off) own.add(_entryKey(path, setting));
    }
  }
  final found = <String, (String, _Setting, Set<String>)>{};
  for (final (path, _) in applied) {
    for (final (origin, setting) in (await walker.merged(path)).values) {
      final key = _entryKey(origin, setting);
      if (!setting.off || own.contains(key)) continue;
      found
          .putIfAbsent(key, () => (origin, setting, <String>{}))
          .$3
          .add(_fromRoot(projectRoot, path));
    }
  }
  return [
    for (final (origin, setting, includedBy) in found.values)
      setting.toIgnore(
        _fromRoot(projectRoot, origin),
        includedBy: List.unmodifiable(includedBy.toList()..sort()),
      ),
  ];
}

/// What names an entry of an options file, whichever way it was reached.
String _entryKey(String path, _Setting setting) =>
    '${p.canonicalize(path)}|${setting.line}|${setting.code}';

/// How many options files one walk follows at most: a guard against a tree
/// of includes that grows beyond reason, which no real project has.
const _maxFollowed = 256;

/// Reads the options files that [_Options.includes] leads to, each once, and
/// merges the settings of a file with those of the files it includes the way
/// the analyzer does (compared with `dart analyze` of the pinned SDK, 3.13.4,
/// on Windows, 2026-10-14):
///
/// - The files an `include:` names are merged in the order written, a later
///   one over an earlier one, and the including file's own entries over all
///   of them, for each code on its own. The letter case of a name doesn't
///   count, and within one file the later entry wins.
/// - A file that includes itself, directly or through others, is cut short
///   where it comes round again, and the rest still applies.
/// - A file that is missing, can't be read or isn't YAML adds nothing, and
///   stops nothing.
final class _IncludeWalker {
  final _cache = <String, Future<_Options?>>{};
  var _followed = 0;

  /// Gives [path] the [content] already read, so it is not read again.
  void seed(String path, String content) {
    _cache[p.canonicalize(path)] = Future.value(_parseOptions(content));
  }

  /// The parsed file at [path]; null when it can't be read.
  Future<_Options?> options(String path) =>
      _cache.putIfAbsent(p.canonicalize(path), () async {
        final content = await _read(path);
        return content == null ? null : _parseOptions(content);
      });

  /// For each code, the setting [path] ends up with once everything it
  /// includes is worked in, and the file that setting is in.
  Future<Map<String, (String, _Setting)>> merged(String path) {
    _followed = 0;
    return _merge(path, {});
  }

  Future<Map<String, (String, _Setting)>> _merge(
    String path,
    Set<String> chain,
  ) async {
    final key = p.canonicalize(path);
    if (chain.contains(key) || ++_followed > _maxFollowed) return const {};
    final options = await this.options(path);
    if (options == null) return const {};
    chain.add(key);
    final result = <String, (String, _Setting)>{};
    for (final include in options.includes) {
      final target = _includedPath(path, include);
      if (target != null) result.addAll(await _merge(target, chain));
    }
    chain.remove(key);
    for (final setting in options.settings) {
      result[setting.code] = (path, setting);
    }
    return result;
  }
}

/// The path of the file the `include:` text [include] names in the options
/// file at [includingPath]; null when it names no local file.
///
/// The analyzer reads the text as a URI and resolves it against the
/// including file: a path is relative to that file's folder (with `/` or, on
/// Windows, `\`, and `%20` for a space), a `file:` URI is that file, and a
/// `package:` URI is a file of a package, which is not followed here. A text
/// with any other scheme, such as `C:/dir/x.yaml` (the analyzer reads the
/// drive letter as a scheme), names no file.
String? _includedPath(String includingPath, String include) {
  final uri = Uri.tryParse(include.trim());
  if (uri == null || include.trim().isEmpty) return null;
  final resolved = Uri.file(p.absolute(includingPath)).resolveUri(uri);
  if (!resolved.isScheme('file')) return null;
  try {
    return resolved.toFilePath();
  } on UnsupportedError {
    return null;
  }
}

/// The path of the nearest `analysis_options.yaml` in a folder above
/// [projectRoot] that the analyzer applies to it; null when the root has an
/// options file of its own (the analyzer then looks no further), or none
/// above it does. Compared with `dart analyze` of the pinned SDK on
/// 2026-10-14: the nearest file wins, with or without a `pubspec.yaml` in
/// between.
Future<String?> _enclosingOptions(String projectRoot) async {
  var folder = p.normalize(p.absolute(projectRoot));
  if (await File(p.join(folder, _optionsName)).exists()) return null;
  while (true) {
    final parent = p.dirname(folder);
    if (parent == folder) return null;
    folder = parent;
    final candidate = p.join(folder, _optionsName);
    if (await File(candidate).exists()) return candidate;
  }
}

const _optionsName = 'analysis_options.yaml';
const _notDart = {'.yaml', '.yml', '.xml'};

/// How many files are open at a time.
const _readAtOnce = 32;

/// The text of the file at [path], with what isn't UTF-8 replaced; null
/// when it can't be read.
Future<String?> _read(String path) async {
  try {
    return utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}
