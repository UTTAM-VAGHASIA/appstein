import '../../docs/doc_page.dart';
import '../../docs/docs_knowledge.dart';
import '../../docs/native_section.dart';

/// Android's section of `native.md` (spec §6.9): what an application ID,
/// the SDK levels and permissions are, then every Android value in
/// `map/native.json` with its file and line.
final class AndroidDocs implements DocPage {
  /// Creates the page source.
  const AndroidDocs();

  /// The concept text, written once here and versioned with the pack.
  static const concepts = [
    "**Application ID.** The app's identity on a device. A different ID is "
        'a different app.',
    '**SDK levels.** `minSdk` is the oldest Android the app installs on, '
        '`targetSdk` the version it was tested against, and `compileSdk` the '
        'version it is built with. A value written as '
        '`flutter.minSdkVersion` comes from the Flutter SDK, so it moves '
        'when Flutter is upgraded. A number written by hand overrides that.',
    '**Permissions.** Each one a manifest declares, with the manifest and '
        'line.',
  ];

  @override
  String get id => 'native';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final markdown = platformSection(
      knowledge.native.sections['android'],
      heading: 'Android',
      concepts: concepts,
      docsPath: knowledge.docsPath,
      flutterPinned: knowledge.sdk.fvmVersion != null,
      // Values written as `flutter.*` come from the Flutter SDK's own files,
      // or from the curated notes for that Flutter version.
      sources: const NativeSources(sdk: {'flutter', 'notes'}),
      headings: const {
        'app': 'App module',
        'settings': 'Build tools',
        'gradle': 'Gradle',
        'manifests': 'Manifests and permissions',
        'gradleProperties': 'Gradle properties',
      },
      order: const [
        'app',
        'settings',
        'gradle',
        'manifests',
        'gradleProperties',
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
