import 'dart:convert';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../docs/support/docs_support.dart';
import '../support/fixture_app.dart';

/// The native config of the fixture that `native.json.golden` was built
/// from: a real `flutter create` app.
NativeConfig get _golden => NativeConfig.fromJson(
  jsonDecode(goldenText('native.json')) as Map<String, Object?>,
);

DocSection? _section(DocPage page, NativeConfig native) =>
    page.sections(sampleKnowledge(native: native)).singleOrNull;

void main() {
  test('the android pack renders its section of native.md', () {
    final section = _section(const AndroidPack().docPages.single, _golden)!;
    expect(section.path, 'native.md');
    expect(section.title, 'Native setup');
    expect(
      section.markdown,
      startsWith(
        '## Android\n'
        '\n'
        "- **Application ID.** The app's identity on a device. A different "
        'ID is a different app.\n'
        '- **SDK levels.** ',
      ),
    );
    expectTextGolden('docs/native-android.md', '${section.markdown}\n');
  });

  test('the ios pack renders its section of native.md', () {
    final section = _section(const IosPack().docPages.single, _golden)!;
    expect(section.path, 'native.md');
    expect(section.title, 'Native setup');
    expect(
      section.markdown,
      startsWith(
        '## iOS\n\n'
        "- **Bundle identifier.** The app's identity on a device.\n",
      ),
    );
    expectTextGolden('docs/native-ios.md', '${section.markdown}\n');
  });

  test('every value of the map is on the page', () {
    final android = _section(const AndroidPack().docPages.single, _golden)!;
    final ios = _section(const IosPack().docPages.single, _golden)!;
    void check(NativeNode node, String text) {
      switch (node) {
        case NativeValue(status: NativeStatus.found, :final value, :final at):
          if (value case final String string) {
            expect(text, contains(mdCode(string)), reason: '$at');
          }
        case NativeValue():
          break;
        case NativeGroup(:final children):
          for (final MapEntry(:key, :value) in children.entries) {
            if (value is NativeValue) {
              expect(text, contains(mdCode(key)));
            }
            check(value, text);
          }
        case NativeList(:final entries):
          for (final entry in entries) {
            expect(text, contains(mdCode(entry.name)));
            check(NativeGroup(entry.children), text);
          }
      }
    }

    check(_golden.sections['android']!, android.markdown);
    check(_golden.sections['ios']!, ios.markdown);
  });

  test('a platform the project does not have says so in one sentence', () {
    final native = NativeConfig({
      'android': const NativeValue.absent('no android/ folder'),
      'ios': const NativeValue.error('StateError'),
    });
    expect(
      _section(const AndroidPack().docPages.single, native)!.markdown,
      '## Android\n\nNot set up in this project: no android/ folder.',
    );
    expect(
      _section(const IosPack().docPages.single, native)!.markdown,
      '## iOS\n\nAppstein failed to read this (StateError). Please report it.',
    );
  });

  test('a pack with nothing in the map contributes nothing', () {
    expect(
      _section(const AndroidPack().docPages.single, NativeConfig(const {})),
      isNull,
    );
    expect(
      _section(const IosPack().docPages.single, NativeConfig(const {})),
      isNull,
    );
  });

  test('both packs write one page, in pack order', () {
    List<RenderedPage> render(List<Pack> packs) => renderPages(
      knowledge: sampleKnowledge(native: _golden),
      sources: [
        for (final pack in packs)
          (id: pack.id, version: pack.version, pages: pack.docPages),
      ],
      readme: readmeSection,
    );
    final both = render(const [AndroidPack(), IosPack()]);
    final page = both.singleWhere((page) => page.path == 'native.md');
    expect(page.title, 'Native setup');
    expect(page.marker.templates, {
      'android': const AndroidPack().version,
      'ios': const IosPack().version,
    });
    expect(
      page.text.indexOf('\n## Android\n'),
      lessThan(page.text.indexOf('\n## iOS\n')),
    );
    final iosOnly = render(const [IosPack()]);
    final only = iosOnly.singleWhere((page) => page.path == 'native.md');
    expect(only.text, isNot(contains('## Android')));
    expect(only.marker.templates.keys, ['ios']);
  });
}
