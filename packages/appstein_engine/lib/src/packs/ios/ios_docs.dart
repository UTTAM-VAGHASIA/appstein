import '../../docs/doc_page.dart';
import '../../docs/docs_knowledge.dart';
import '../../docs/native_section.dart';
import 'swiftpm_setting.dart';

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
      flutterPinned: knowledge.sdk.fvmVersion != null,
      // Whether Swift Package Manager is on can come from the project's
      // pubspec, from one machine's Flutter config or environment, or from
      // the default of the Flutter in use.
      sources: const NativeSources(
        sdk: {'default'},
        machine: {'flutter config (global)', swiftPackageManagerVariable},
      ),
      // Read from `ios/Flutter/ephemeral/`, which is git-ignored and which
      // Flutter fills in differently on a Mac.
      omit: const {'generatedPackage'},
      headings: const {
        'xcode': 'Xcode project',
        'infoPlist': 'Info.plist',
        'swiftPackageManager': 'Swift Package Manager',
      },
      order: const ['xcode', 'infoPlist', 'swiftPackageManager'],
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
