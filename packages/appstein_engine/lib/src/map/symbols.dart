import 'package:analyzer/dart/element/element.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import 'project_analysis.dart';

/// Builds `symbols.json` (spec §6.5). It lists every public top-level class,
/// mixin, enum, named extension, extension type, typedef and function
/// declared in `lib/`, sorted by file, then line, then name.
///
/// [layerOf] and [featureOf] give each symbol's file its layer tag and
/// feature.
SymbolsMap buildSymbols(
  ProjectAnalysis analysis, {
  required String? Function(String file) layerOf,
  required String? Function(String file) featureOf,
}) {
  final symbols = <MapSymbol>[];
  void add(Element element, SymbolKind kind) {
    final name = element.name;
    if (name == null || !element.isPublic) return;
    final location = analysis.locationOf(element.firstFragment);
    if (location == null || !location.file.startsWith('lib/')) return;
    symbols.add(
      MapSymbol(
        name: name,
        kind: kind,
        file: location.file,
        line: location.line,
        layer: layerOf(location.file),
        feature: featureOf(location.file),
        summary: docSummary(element.documentationComment),
      ),
    );
  }

  for (final library in analysis.libraries) {
    if (!library.path.startsWith('lib/')) continue;
    final element = library.result.element;
    for (final e in element.classes) {
      add(e, SymbolKind.classKind);
    }
    for (final e in element.mixins) {
      add(e, SymbolKind.mixinKind);
    }
    for (final e in element.enums) {
      add(e, SymbolKind.enumKind);
    }
    for (final e in element.extensions) {
      add(e, SymbolKind.extension);
    }
    for (final e in element.extensionTypes) {
      add(e, SymbolKind.extensionType);
    }
    for (final e in element.typeAliases) {
      add(e, SymbolKind.typedef);
    }
    for (final e in element.topLevelFunctions) {
      add(e, SymbolKind.function);
    }
  }
  symbols.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    if (byFile != 0) return byFile;
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.name.compareTo(b.name);
  });
  return SymbolsMap(symbols: symbols);
}

/// The summary `symbols.json` records for a doc [comment] (spec §6.5): the
/// first sentence of its first paragraph, or null when there is no comment
/// or it is empty.
///
/// A sentence ends at `.`, `!` or `?` followed by a space or the end, so
/// "v1.2" doesn't end one. Both `///` and `/** */` comments are read.
String? docSummary(String? comment) {
  if (comment == null) return null;
  final lines = <String>[];
  for (final raw in comment.split('\n')) {
    var line = raw.trim();
    if (line.startsWith('///')) {
      line = line.substring(3);
    } else {
      if (line.startsWith('/**')) line = line.substring(3);
      if (line.endsWith('*/')) line = line.substring(0, line.length - 2);
      line = line.trim();
      if (line.startsWith('*')) line = line.substring(1);
    }
    line = line.trim();
    if (line.isEmpty) {
      if (lines.isNotEmpty) break;
      continue;
    }
    lines.add(line);
  }
  if (lines.isEmpty) return null;
  final paragraph = lines.join(' ');
  final end = RegExp(r'[.!?](?=\s|$)').firstMatch(paragraph);
  return end == null ? paragraph : paragraph.substring(0, end.end);
}
