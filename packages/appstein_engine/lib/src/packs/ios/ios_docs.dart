import '../../docs/doc_page.dart';
import '../../docs/docs_knowledge.dart';
import '../../docs/native_section.dart';

/// iOS's section of `native.md` (spec §6.9): what a bundle identifier, the
/// deployment target and usage descriptions are, then every iOS value in
/// `map/native.json` with its file and line.
final class IosDocs implements DocPage {
  /// Creates the page source.
  const IosDocs();

  /// The concept text, written once here and versioned with the pack.
  static const concepts = [
    "**Bundle identifier.** The app's identity on a device.",
    '**Deployment target.** The oldest iOS the app runs on.',
    '**Usage descriptions.** The `Info.plist` texts iOS shows when the app '
        'asks for the camera, location and so on.',
  ];

  @override
  String get id => 'native';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final markdown = platformSection(
      knowledge.native.sections['ios'],
      heading: 'iOS',
      concepts: concepts,
      docsPath: knowledge.docsPath,
      headings: const {
        'xcode': 'Xcode project',
        'infoPlist': 'Info.plist',
        'swiftPackageManager': 'Swift Package Manager',
        'generatedPackage': 'Generated plugin package',
      },
      order: const [
        'xcode',
        'infoPlist',
        'swiftPackageManager',
        'generatedPackage',
      ],
    );
    return [
      if (markdown != null)
        DocSection(
          path: nativePagePath,
          title: nativePageTitle,
          markdown: markdown,
        ),
    ];
  }
}
