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

const _pinned = SdkInfo(
  flutterVersion: '3.47.5',
  dartVersion: '3.13.4',
  channel: 'stable',
  fvmVersion: '3.47.5',
);

/// The section [page] renders for [native], in a project that pins Flutter
/// unless [pinned] is false.
DocSection? _section(DocPage page, NativeConfig native, {bool pinned = true}) =>
    page
        .sections(sampleKnowledge(native: native, sdk: pinned ? _pinned : null))
        .singleOrNull;

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

  test('a project that does not pin Flutter gets no number that follows '
      'the installed SDK', () {
    final pinned = _section(const AndroidPack().docPages.single, _golden)!;
    final free = _section(
      const AndroidPack().docPages.single,
      _golden,
      pinned: false,
    )!;
    const row = '| `minSdk` | ';
    expect(
      pinned.markdown,
      contains('$row`24`, written as `flutter.minSdkVersion` (from flutter)'),
    );
    expect(
      free.markdown,
      contains(
        '${row}written as `flutter.minSdkVersion`; the value follows the '
        'Flutter SDK in use |',
      ),
    );
    // What the project's own files set is on both.
    for (final text in [pinned.markdown, free.markdown]) {
      expect(text, contains('| `applicationId` | `dev.sample.probe_app` |'));
      expect(text, contains('`1.0.0`, written as `flutter.versionName`'));
    }
    expect(
      free.markdown,
      contains(
        'follows the Flutter SDK in use" means the number comes from the '
        'Flutter each machine has',
      ),
    );
    expect(pinned.markdown, isNot(contains('each machine has')));
  });

  test('the ios page holds nothing that differs between machines', () {
    for (final pinned in [true, false]) {
      final text = _section(
        const IosPack().docPages.single,
        _golden,
        pinned: pinned,
      )!.markdown;
      // Read from a git-ignored folder Flutter fills in differently on a
      // Mac.
      expect(text, isNot(contains('Generated plugin package')));
      expect(text, isNot(contains('ephemeral')));
    }
    NativeConfig swiftPm(NativeValue enabled) => NativeConfig({
      'ios': NativeGroup({
        'swiftPackageManager': NativeGroup({'enabled': enabled}),
      }),
    });
    String render(NativeValue enabled, {bool pinned = true}) => _section(
      const IosPack().docPages.single,
      swiftPm(enabled),
      pinned: pinned,
    )!.markdown;
    expect(
      render(
        const NativeValue.found(
          true,
          at: 'pubspec.yaml:30',
          resolvedFrom: 'pubspec.yaml',
        ),
        pinned: false,
      ),
      contains('| `enabled` | `true` (from pubspec.yaml) |'),
    );
    for (final machine in [
      'flutter config (global)',
      'FLUTTER_SWIFT_PACKAGE_MANAGER',
    ]) {
      final text = render(NativeValue.found(false, resolvedFrom: machine));
      expect(text, contains('set on each machine (`$machine`)'));
      expect(text, isNot(contains('`false`')));
    }
    const byDefault = NativeValue.found(
      true,
      resolvedFrom: 'default',
      note: 'on by default since Flutter 3.44',
    );
    expect(render(byDefault), contains('`true` (from default)'));
    expect(
      render(byDefault, pinned: false),
      contains('| `enabled` | follows the Flutter SDK in use |'),
    );
  });

  test('every value of the map is on the page of a project that pins '
      'Flutter', () {
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
            // The one part left out on purpose (see the test above).
            if (key == 'generatedPackage') continue;
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
