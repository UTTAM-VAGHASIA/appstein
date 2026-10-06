import 'package:appstein_protocol/appstein_protocol.dart';

import '../../index/index_sources.dart';
import '../doc_page.dart';
import '../docs_knowledge.dart';
import '../docs_renderer.dart';
import '../markdown_text.dart';

/// The folder every feature page is in.
const featurePagesFolder = 'features/';

/// `README.md` (spec §6.9): what the app is, how to run it, and a list of
/// every page in [pages] and every team note.
DocSection readmeSection(DocsKnowledge knowledge, List<RenderedPage> pages) {
  final sdk = knowledge.sdk;
  final facts = <List<String>>[
    ['Stack', mdCode(knowledge.stack)],
    [
      'Platforms',
      knowledge.platforms.isEmpty
          ? 'none'
          : knowledge.platforms.map(mdText).join(', '),
    ],
    ['Flutter', '${mdText(sdk.flutterVersion)} (${mdText(sdk.channel)})'],
    ['Dart', mdText(sdk.dartVersion)],
    if (sdk.languageVersion case final version?)
      ['Language version', mdText(version)],
    // The lines INDEX.md shows, so the two never disagree. Their values are
    // already Markdown; the pointer to the map becomes one to the page.
    for (final line in appIdLines(knowledge.native))
      if (line.indexOf(': ') case final colon when colon > 0)
        [
          line.substring(0, colon),
          line
              .substring(colon + 2)
              .replaceAll('see `map/native.json`', 'see the native setup page'),
        ],
  ];

  final fvm = sdk.fvmVersion == null ? '' : 'fvm ';
  final flavors = switch (knowledge.native.lookup(const [
    'android',
    'app',
    'flavors',
  ])) {
    NativeList(:final entries) => [for (final entry in entries) entry.name],
    _ => const <String>[],
  };

  String link(String path, String text) =>
      '- ${pageLink(page: readmePath, other: path, text: text)}';
  final topPages = [
    for (final page in pages)
      if (!page.path.startsWith(featurePagesFolder)) page,
  ];
  final featurePages = [
    for (final page in pages)
      if (page.path.startsWith(featurePagesFolder)) page,
  ];

  final parts = <String>[
    'This folder describes the app as it is now. Appstein renders it from '
        'the code, the doc comments and the recorded decisions.',
    mdTable(const ['', ''], facts).trimRight(),
    '## Run it\n\n'
        '```sh\n${fvm}flutter pub get\n${fvm}flutter run\n```'
        '${flavors.isEmpty ? '' : '\n\nThe Android app has flavors '
                  '(${flavors.map(mdCode).join(', ')}): add '
                  '`--flavor <name>` to `flutter run`.'}',
    if (topPages.isNotEmpty)
      '## Pages\n\n'
          '${topPages.map((page) => link(page.path, page.title)).join('\n')}',
    if (featurePages.isNotEmpty)
      '## Features\n\n'
          '${featurePages.map((page) => link(page.path, page.title)).join('\n')}',
    if (knowledge.teamNotes.isNotEmpty)
      '## Team notes\n\n'
          'Written by the team. Appstein never changes them.\n\n'
          '${knowledge.teamNotes.map((note) => link(note.path, note.title)).join('\n')}',
  ];
  return DocSection(
    path: readmePath,
    title: knowledge.projectName ?? 'This app',
    markdown: parts.join('\n\n'),
  );
}
