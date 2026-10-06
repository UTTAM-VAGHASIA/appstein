import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/docs_support.dart';

RenderedPage _page(String path, String title) => RenderedPage(
  path: path,
  title: title,
  text: '',
  marker: const DocMarker(templates: {}, body: ''),
);

final _pages = [
  _page('architecture.md', 'Architecture'),
  _page('features/auth/login.md', 'Feature: auth/login'),
  _page('features/booking.md', 'Feature: booking'),
  _page('routes.md', 'Routes'),
];

const _intro =
    'This folder describes the app as it is now. Appstein renders it from '
    'the code, the doc comments and the recorded decisions.';

NativeConfig _android({List<String> flavors = const []}) => NativeConfig({
  'android': NativeGroup({
    'app': NativeGroup({
      'applicationId': const NativeValue.found(
        'dev.sample.app',
        at: 'android/app/build.gradle.kts:19',
      ),
      'flavors': NativeList([
        for (final flavor in flavors) NativeEntry(flavor, const {}),
      ]),
    }),
  }),
});

void main() {
  test('says what the app is, how to run it and what to read', () {
    final section = readmeSection(sampleKnowledge(native: _android()), _pages);
    expect(section.path, 'README.md');
    expect(section.title, 'sample_app');
    expect(
      section.markdown,
      '$_intro\n'
      '\n'
      '|  |  |\n'
      '|---|---|\n'
      '| Stack | `official_mvvm` |\n'
      '| Platforms | android, ios |\n'
      '| Flutter | 3.47.5 (stable) |\n'
      '| Dart | 3.13.4 |\n'
      '| Language version | 3.12 |\n'
      '| Android applicationId | `dev.sample.app` |\n'
      '\n'
      '## Run it\n'
      '\n'
      '```sh\n'
      'flutter pub get\n'
      'flutter run\n'
      '```\n'
      '\n'
      '## Pages\n'
      '\n'
      '- [Architecture](architecture.md)\n'
      '- [Routes](routes.md)\n'
      '\n'
      '## Features\n'
      '\n'
      '- [Feature: auth/login](features/auth/login.md)\n'
      '- [Feature: booking](features/booking.md)',
    );
  });

  test('runs through FVM when the project pins Flutter with it', () {
    final text = readmeSection(
      sampleKnowledge(
        sdk: const SdkInfo(
          flutterVersion: '3.47.5',
          dartVersion: '3.13.4',
          channel: 'stable',
          fvmVersion: '3.47.5',
        ),
      ),
      _pages,
    ).markdown;
    expect(text, contains('```sh\nfvm flutter pub get\nfvm flutter run\n```'));
    expect(text, isNot(contains('Language version')));
  });

  test('groups the pages of any folder under the folder name', () {
    final text = readmeSection(sampleKnowledge(), [
      _page('architecture.md', 'Architecture'),
      _page('blocs/cart.md', 'Bloc: cart'),
      _page('features/booking.md', 'Feature: booking'),
      _page('features/shop/cart.md', 'Feature: shop/cart'),
    ]).markdown;
    expect(
      text,
      endsWith(
        '## Pages\n'
        '\n'
        '- [Architecture](architecture.md)\n'
        '\n'
        '## Blocs\n'
        '\n'
        '- [Bloc: cart](blocs/cart.md)\n'
        '\n'
        '## Features\n'
        '\n'
        '- [Feature: booking](features/booking.md)\n'
        '- [Feature: shop/cart](features/shop/cart.md)',
      ),
    );
  });

  test('the run steps hold nothing about one platform', () {
    final text = readmeSection(
      sampleKnowledge(native: _android(flavors: const ['prod', 'dev'])),
      _pages,
    ).markdown;
    expect(text, contains('flutter run\n```\n\n## Pages'));
    expect(text, isNot(contains('--flavor')));
  });

  test('points to the native page for an id it cannot show', () {
    final text = readmeSection(
      sampleKnowledge(
        native: NativeConfig({
          'android': NativeGroup({
            'app': NativeGroup({
              'applicationId': const NativeValue.unknown('computed in code'),
            }),
          }),
        }),
      ),
      _pages,
    ).markdown;
    expect(
      text,
      contains(
        '| Android applicationId | unknown; see the native setup page |',
      ),
    );
    expect(text, isNot(contains('native.json')));
  });

  test('works without a name, platforms, features or other pages', () {
    final section = readmeSection(
      sampleKnowledge(projectName: null, platforms: const []),
      const [],
    );
    expect(section.title, 'This app');
    expect(section.markdown, contains('| Platforms | none |'));
    expect(section.markdown, isNot(contains('## Pages')));
    expect(section.markdown, isNot(contains('## Features')));
    expect(section.markdown, isNot(contains('## Team notes')));
    expect(section.markdown, endsWith('flutter run\n```'));
  });

  test('lists the team notes by title', () {
    expect(
      readmeSection(
        sampleKnowledge(
          teamNotes: const [
            TeamNote(path: 'onboarding.md', title: 'Start here'),
            TeamNote(path: 'run books/deploy it.md', title: 'Deploy | prod'),
          ],
        ),
        _pages,
      ).markdown,
      endsWith(
        '## Team notes\n'
        '\n'
        'Written by the team. Appstein never changes them.\n'
        '\n'
        '- [Start here](onboarding.md)\n'
        r'- [Deploy \| prod](run%20books/deploy%20it.md)',
      ),
    );
  });
}
