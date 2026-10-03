import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../delta/delta_json.dart';
import '../host/file_errors.dart';
import '../knowledge/markdown_front_matter.dart';
import 'tool_answer.dart';

/// `INDEX.md`'s text without its front matter, and when it was generated.
typedef IndexText = ({String body, String generatedAt});

/// One knowledge file as an MCP tool reads it: its contents, or why it
/// can't be used.
final class KnowledgeRead<T> {
  /// A file that was read.
  const KnowledgeRead.loaded(T this.value) : problem = null;

  /// A file that is missing, unreadable or damaged.
  const KnowledgeRead.missing(String this.problem) : value = null;

  /// The contents; null when [problem] is set.
  final T? value;

  /// Why the file can't be used, naming it; null when it was read.
  final String? problem;
}

/// The knowledge files of a project's `.appstein/` (spec §6.2), each read
/// on first use, for one MCP tool call (spec §8).
///
/// Writers replace each file in one step, so a reader sees a whole file:
/// the old one or the new one.
final class KnowledgeSnapshot {
  /// The snapshot of the project at [projectRoot].
  KnowledgeSnapshot(this.projectRoot);

  /// The project's folder.
  final String projectRoot;

  /// `INDEX.md`.
  late final KnowledgeRead<IndexText> index = _read('INDEX.md', (text) {
    final meta = readFrontMatter(text);
    if (meta == null) throw const FormatException('it has no front matter');
    final end = text.indexOf('\n---\n', 3);
    return (
      body: text.substring(end + 5).replaceFirst(RegExp('^\n'), ''),
      generatedAt: meta.generatedAt,
    );
  });

  /// `platform/toolchain.json`.
  late final KnowledgeRead<Toolchain> toolchain = _json(
    'platform/toolchain.json',
    Toolchain.fromJson,
  );

  /// `platform/delta.json`.
  late final KnowledgeRead<DeltaKnowledge> delta = _json(
    deltaJsonPath,
    DeltaKnowledge.fromJson,
  );

  /// `map/features.json`.
  late final KnowledgeRead<FeaturesMap> features = _json(
    MapFiles.features,
    FeaturesMap.fromJson,
  );

  /// `map/symbols.json`.
  late final KnowledgeRead<SymbolsMap> symbols = _json(
    MapFiles.symbols,
    SymbolsMap.fromJson,
  );

  /// `map/routes.json`.
  late final KnowledgeRead<RoutesMap> routes = _json(
    MapFiles.routes,
    RoutesMap.fromJson,
  );

  /// `map/layers.json`.
  late final KnowledgeRead<LayersMap> layers = _json(
    MapFiles.layers,
    LayersMap.fromJson,
  );

  /// `map/native.json`.
  late final KnowledgeRead<NativeConfig> native = _json(
    MapFiles.native,
    NativeConfig.fromJson,
  );

  /// A refusal naming the first of [reads] that can't be used, with what
  /// to do; null when all of them were read.
  ToolRefusal? refusalFor(List<KnowledgeRead<Object>> reads) {
    for (final read in reads) {
      if (read.problem case final problem?) {
        return ToolRefusal(
          "$problem, so this can't be answered yet. Run `appstein sync` in "
          'the project to see why.',
        );
      }
    }
    return null;
  }

  KnowledgeRead<T> _json<T extends Object>(
    String path,
    T Function(Map<String, Object?> json) parse,
  ) => _read(path, (text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('it is not a JSON object');
    }
    return parse(json);
  });

  KnowledgeRead<T> _read<T extends Object>(
    String path,
    T Function(String text) parse,
  ) {
    final name = '`.appstein/$path`';
    final file = File(
      p.joinAll([projectRoot, '.appstein', ...path.split('/')]),
    );
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (error) {
      return KnowledgeRead.missing(
        file.existsSync()
            ? '$name could not be read (${fileErrorReason(error)})'
            : '$name is missing',
      );
    }
    try {
      return KnowledgeRead.loaded(parse(utf8.decode(bytes)));
    } on FormatException catch (error) {
      return KnowledgeRead.missing('$name is damaged (${error.message})');
    }
  }
}
