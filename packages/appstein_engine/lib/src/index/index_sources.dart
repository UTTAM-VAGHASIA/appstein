import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../delta/delta_facts.dart';
import '../host/file_errors.dart';

/// The platform folders a Flutter project can have, in the order `INDEX.md`
/// lists them. Flutter decides which platforms a project has by which of
/// these folders exist.
const platformFolderNames = [
  'android',
  'ios',
  'linux',
  'macos',
  'web',
  'windows',
];

/// One row of `INDEX.md`'s features table (spec §6.3).
final class IndexFeature {
  /// Creates the row.
  const IndexFeature({
    required this.name,
    required this.folder,
    required this.screens,
    required this.mainFiles,
  });

  /// The feature's name, such as `auth/login`.
  final String name;

  /// Its folder, such as `lib/ui/auth/login`.
  final String folder;

  /// How many screens it has.
  final int screens;

  /// Its main files, relative to [folder]: the screens' files, then the view
  /// models' files; its files when it has neither.
  final List<String> mainFiles;
}

/// One decision file `INDEX.md` reads (spec §6.3, §6.7).
final class IndexDecision {
  /// A decision whose front matter was read.
  const IndexDecision({
    required this.file,
    this.id,
    required String this.title,
    required String this.status,
  }) : problem = null;

  /// A decision file whose front matter can't be read, and why.
  const IndexDecision.unreadable({
    required this.file,
    this.id,
    required String this.problem,
  }) : title = null,
       status = null;

  /// Its file name inside `.appstein/decisions/`, such as `0002-state.md`.
  final String file;

  /// The number its file name starts with, such as `0002`; null when it
  /// doesn't start with one.
  final String? id;

  /// Its title, on one line; null when it can't be read.
  final String? title;

  /// `accepted`, `proposed` or `superseded`; null when it can't be read.
  final String? status;

  /// Why it can't be read; null when it was read.
  final String? problem;
}

/// How many APIs `delta.md` lists besides its notes.
final class DeltaCounts {
  /// Creates the counts.
  const DeltaCounts({
    required this.deprecated,
    required this.removed,
    required this.changed,
    required this.moved,
  });

  /// Counts what [facts] holds.
  factory DeltaCounts.of(DeltaFacts facts) => DeltaCounts(
    deprecated: facts.deprecated.length,
    removed: facts.migrated
        .where((api) => api.status == MigrationStatus.removed)
        .length,
    changed: facts.migrated
        .where((api) => api.status == MigrationStatus.changed)
        .length,
    moved: facts.moved.length,
  );

  /// Deprecated APIs.
  final int deprecated;

  /// Removed APIs.
  final int removed;

  /// Changed APIs.
  final int changed;

  /// Moved libraries.
  final int moved;
}

/// What `INDEX.md` reads from the project itself.
final class IndexSources {
  /// Creates the sources.
  const IndexSources({
    required this.projectName,
    required this.platforms,
    required this.decisions,
    required this.decisionsError,
    required this.currentWork,
    required this.currentWorkError,
    required this.inputs,
  });

  /// The name in `pubspec.yaml`; null when it can't be read.
  final String? projectName;

  /// The platform folders that exist ([platformFolders]).
  final List<String> platforms;

  /// The accepted and proposed decisions, and the unreadable decision
  /// files, in file-name order. Superseded decisions are left out.
  final List<IndexDecision> decisions;

  /// Why `.appstein/decisions/` couldn't be listed; null otherwise.
  final String? decisionsError;

  /// The lines of `memory/current.md` ([currentWorkLines]); empty when it
  /// doesn't exist.
  final List<String> currentWork;

  /// Why `memory/current.md` couldn't be read; null otherwise.
  final String? currentWorkError;

  /// What `INDEX.md`'s input hash covers from the project: `pubspec.yaml`,
  /// the platform list, each decision file and `memory/current.md`, by
  /// name.
  final Map<String, List<int>?> inputs;
}

/// Reads what `INDEX.md` needs from the project at [projectRoot]: its name,
/// its platform folders, the decision files in `.appstein/decisions/` and
/// `.appstein/memory/current.md` (spec §6.3).
///
/// It never throws for the project's own files: a file or folder that
/// can't be read is reported in [IndexSources.decisionsError],
/// [IndexSources.currentWorkError] or [IndexDecision.problem].
IndexSources readIndexSources(String projectRoot) {
  final pubspec = _bytes(p.join(projectRoot, 'pubspec.yaml'));
  final platforms = platformFolders(projectRoot);
  final inputs = <String, List<int>?>{
    'pubspec.yaml': pubspec,
    'platforms': utf8.encode(platforms.join(',')),
  };

  final decisions = <IndexDecision>[];
  String? decisionsError;
  final folder = Directory(p.join(projectRoot, '.appstein', 'decisions'));
  if (folder.existsSync()) {
    try {
      final files = [
        for (final entity in folder.listSync(followLinks: false))
          if (entity is File && entity.path.endsWith('.md')) entity,
      ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final file in files) {
        final name = p.basename(file.path);
        try {
          final bytes = file.readAsBytesSync();
          inputs['decisions/$name'] = bytes;
          final decision = parseDecision(
            name,
            utf8.decode(bytes, allowMalformed: true),
          );
          if (decision.status != 'superseded') decisions.add(decision);
        } on FileSystemException catch (error) {
          final reason = fileErrorReason(error);
          inputs['decisions/$name'] = utf8.encode('unreadable: $reason');
          decisions.add(
            IndexDecision.unreadable(
              file: name,
              id: decisionNumber(name),
              problem: reason,
            ),
          );
        }
      }
    } on FileSystemException catch (error) {
      decisionsError = fileErrorReason(error);
      inputs['decisions'] = utf8.encode('unreadable: $decisionsError');
      decisions.clear();
    }
  }

  var currentWork = const <String>[];
  String? currentWorkError;
  final current = File(
    p.join(projectRoot, '.appstein', 'memory', 'current.md'),
  );
  if (current.existsSync()) {
    try {
      final bytes = current.readAsBytesSync();
      inputs['memory/current.md'] = bytes;
      currentWork = currentWorkLines(utf8.decode(bytes, allowMalformed: true));
    } on FileSystemException catch (error) {
      currentWorkError = fileErrorReason(error);
      inputs['memory/current.md'] = utf8.encode(
        'unreadable: $currentWorkError',
      );
    }
  }

  return IndexSources(
    projectName: projectNameOf(pubspec),
    platforms: platforms,
    decisions: decisions,
    decisionsError: decisionsError,
    currentWork: currentWork,
    currentWorkError: currentWorkError,
    inputs: inputs,
  );
}

/// The `name:` in the bytes of a `pubspec.yaml`, or null when there are no
/// bytes, they aren't valid UTF-8 or YAML, or the name isn't a string.
String? projectNameOf(List<int>? pubspec) {
  if (pubspec == null) return null;
  try {
    final yaml = loadYaml(utf8.decode(pubspec));
    if (yaml is! Map) return null;
    final name = yaml['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  } on FormatException {
    // YamlException is a FormatException too.
    return null;
  }
}

/// The platform folders of the project at [projectRoot], from
/// [platformFolderNames], in that order.
List<String> platformFolders(String projectRoot) => [
  for (final name in platformFolderNames)
    if (Directory(p.join(projectRoot, name)).existsSync()) name,
];

const _seeNative = 'see `map/native.json`';

/// The app and bundle id lines of `INDEX.md` (spec §6.3) from [native]:
/// the Android `applicationId` and the iOS bundle id, each only when its
/// platform folder exists. An id that isn't a plain found value is
/// `unknown`, never guessed.
List<String> appIdLines(NativeConfig? native) {
  if (native == null) return const [];
  return [?_androidId(native), ?_iosId(native)];
}

String? _androidId(NativeConfig native) {
  const label = 'Android applicationId';
  final section = native.sections['android'];
  if (section == null) return null;
  if (section is NativeValue) {
    return section.status == NativeStatus.absent
        ? null
        : '$label: unknown; $_seeNative';
  }
  final id = _plainId(native.lookup(['android', 'app', 'applicationId']));
  if (id == null) return '$label: unknown; $_seeNative';
  final flavors = native.lookup(['android', 'app', 'flavors']);
  final count = flavors is NativeList ? flavors.entries.length : 0;
  if (count == 0) return '$label: `$id`';
  final noun = count == 1 ? '1 flavor' : '$count flavors';
  return '$label: `$id` ($noun may change it; $_seeNative)';
}

String? _iosId(NativeConfig native) {
  const label = 'iOS bundle id';
  final section = native.sections['ios'];
  if (section == null) return null;
  if (section is NativeValue) {
    return section.status == NativeStatus.absent
        ? null
        : '$label: unknown; $_seeNative';
  }
  final configurations = native.lookup(['ios', 'xcode', 'configurations']);
  if (configurations is! NativeList || configurations.entries.isEmpty) {
    return '$label: unknown; $_seeNative';
  }
  // NativeList keeps its entries sorted by name.
  final ids = <String, String>{};
  for (final entry in configurations.entries) {
    final id = _plainId(entry.children['bundleIdentifier']);
    if (id == null) return '$label: unknown; $_seeNative';
    ids[entry.name] = id;
  }
  final distinct = ids.values.toSet();
  if (distinct.length == 1) return '$label: `${distinct.single}`';
  return '$label: '
      '${[for (final MapEntry(:key, :value) in ids.entries) '$key `$value`'].join(', ')}';
}

/// [node]'s value when it is a found, non-empty string with no Xcode build
/// variable (`$(…)`) in it; null otherwise.
String? _plainId(NativeNode? node) => switch (node) {
  NativeValue(status: NativeStatus.found, value: final String value)
      when value.isNotEmpty && !value.contains(r'$(') =>
    value,
  _ => null,
};

/// The rows of `INDEX.md`'s features table: most screens first, then by
/// name.
List<IndexFeature> indexFeatures(FeaturesMap map) {
  final rows = [
    for (final MapEntry(key: name, value: feature) in map.features.entries)
      IndexFeature(
        name: name,
        folder: feature.folder,
        screens: feature.screens.length,
        mainFiles: _mainFiles(feature),
      ),
  ];
  rows.sort((a, b) {
    final byScreens = b.screens.compareTo(a.screens);
    return byScreens != 0 ? byScreens : a.name.compareTo(b.name);
  });
  return rows;
}

List<String> _mainFiles(Feature feature) {
  final main = <String>{
    for (final ref in feature.screens) ref.file,
    for (final ref in feature.viewModels) ref.file,
  };
  final chosen = main.isEmpty ? feature.files : main.toList();
  return [
    for (final file in chosen)
      p.posix.isWithin(feature.folder, file)
          ? p.posix.relative(file, from: feature.folder)
          : file,
  ];
}

/// The number a decision file's name starts with, such as `0002` in
/// `0002-state.md`; null when it doesn't start with digits and `-`.
String? decisionNumber(String file) =>
    RegExp(r'^(\d+)-').firstMatch(file)?.group(1);

/// Reads the front matter of the decision file [file] whose text is [text]
/// (spec §6.7): its title and status. Anything that keeps them from being
/// read gives an [IndexDecision.unreadable] that says why.
IndexDecision parseDecision(String file, String text) {
  final id = decisionNumber(file);
  IndexDecision unreadable(String problem) =>
      IndexDecision.unreadable(file: file, id: id, problem: problem);

  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    return unreadable('it has no front matter');
  }
  final end = lines.indexWhere((line) => line.trimRight() == '---', 1);
  if (end < 0) return unreadable('its front matter has no closing ---');
  final Object? yaml;
  try {
    yaml = loadYaml(lines.sublist(1, end).join('\n'));
  } on FormatException {
    return unreadable('its front matter is not valid YAML');
  }
  if (yaml is! Map) return unreadable('its front matter is not a map');
  final title = yaml['title'];
  if (title == null || '$title'.trim().isEmpty) {
    return unreadable('it has no title');
  }
  final status = yaml['status'];
  if (status is! String ||
      !const ['accepted', 'proposed', 'superseded'].contains(status)) {
    return unreadable('its status is not accepted, proposed or superseded');
  }
  return IndexDecision(
    file: file,
    id: id,
    title: _cap(_oneLine('$title'), 120),
    status: status,
  );
}

/// The lines of a `memory/current.md` [text]: any line break, trailing
/// white space dropped, blank lines at the start and the end dropped, and
/// each line at most 160 characters.
List<String> currentWorkLines(String text) {
  final lines = [
    for (final line in const LineSplitter().convert(text))
      _cap(line.trimRight(), 160),
  ];
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// [text] with each run of white space as one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text], or its first [max] - 1 characters and `…` when it is longer. It
/// counts runes, so a character outside the Basic Multilingual Plane is
/// never split.
String _cap(String text, int max) {
  final runes = text.runes.toList();
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}

List<int>? _bytes(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
}
