import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

({String value, String where}) _cells(NativeValue value) =>
    nativeCells(value, docsPath: 'docs/app', page: 'native.md');

String _tables(
  NativeGroup group, {
  Map<String, String> headings = const {},
  List<String> order = const [],
}) => nativeTables(
  group,
  docsPath: 'docs/app',
  page: 'native.md',
  headings: headings,
  order: order,
);

void main() {
  group('nativeCells', () {
    test('a plain value, with where it is', () {
      final cells = _cells(
        const NativeValue.found(
          'dev.sample.app',
          at: 'android/app/build.gradle.kts:19',
        ),
      );
      expect(cells.value, '`dev.sample.app`');
      expect(
        cells.where,
        '[android/app/build.gradle.kts:19]'
        '(../../android/app/build.gradle.kts#L19)',
      );
    });

    test('a value written as an expression says where it came from', () {
      expect(
        _cells(
          const NativeValue.found(
            24,
            at: 'android/app/build.gradle.kts:22',
            expression: 'flutter.minSdkVersion',
            resolvedFrom: 'flutter',
          ),
        ).value,
        '`24`, written as `flutter.minSdkVersion` (from flutter)',
      );
      expect(
        _cells(
          const NativeValue.found(
            true,
            resolvedFrom: 'default',
            note: 'on by default since Flutter 3.44',
          ),
        ),
        (
          value: '`true` (from default); on by default since Flutter 3.44',
          where: '',
        ),
      );
    });

    test('a list value, and an empty one', () {
      expect(
        _cells(const NativeValue.found(['a.b', 'c|d'])).value,
        r'`a.b`, `c\|d`',
      );
      expect(_cells(const NativeValue.found(<String>[])).value, 'none');
    });

    test('a place without a line', () {
      expect(
        _cells(
          const NativeValue.found('x', at: 'ios/Runner/Info plist.xml'),
        ).where,
        '[ios/Runner/Info plist.xml](../../ios/Runner/Info%20plist.xml)',
      );
    });

    test('unknown and absent values say why, and are never guessed', () {
      expect(
        _cells(
          const NativeValue.unknown(
            'it is computed in Gradle code',
            at: 'android/app/build.gradle.kts:30',
          ),
        ),
        (
          value: 'unknown: it is computed in Gradle code',
          where:
              '[android/app/build.gradle.kts:30]'
              '(../../android/app/build.gradle.kts#L30)',
        ),
      );
      expect(_cells(const NativeValue.absent('the file has no such key')), (
        value: 'not set: the file has no such key',
        where: '',
      ));
    });

    test('an internal error asks for a report', () {
      expect(
        _cells(const NativeValue.error('StateError')).value,
        'Appstein failed to read this (StateError). Please report it.',
      );
    });
  });

  group('nativeTables', () {
    test('a table of values, named groups first, then the rest', () {
      expect(
        _tables(
          NativeGroup({
            'zeta': NativeGroup({'b': const NativeValue.found('2')}),
            'buildLanguage': const NativeValue.found('kts'),
            'app': NativeGroup({
              'minSdk': const NativeValue.found(24),
              'applicationId': const NativeValue.found('a.b'),
            }),
            'alpha': NativeGroup({'a': const NativeValue.found('1')}),
          }),
          headings: const {'app': 'App module'},
          order: const ['app'],
        ),
        '| Setting | Value | Where |\n'
        '|---|---|---|\n'
        '| `buildLanguage` | `kts` |  |\n'
        '\n'
        '### App module\n'
        '\n'
        '| Setting | Value | Where |\n'
        '|---|---|---|\n'
        '| `applicationId` | `a.b` |  |\n'
        '| `minSdk` | `24` |  |\n'
        '\n'
        '### `alpha`\n'
        '\n'
        '| Setting | Value | Where |\n'
        '|---|---|---|\n'
        '| `a` | `1` |  |\n'
        '\n'
        '### `zeta`\n'
        '\n'
        '| Setting | Value | Where |\n'
        '|---|---|---|\n'
        '| `b` | `2` |  |',
      );
    });

    test('a list is a table with one row per entry', () {
      expect(
        _tables(
          NativeGroup({
            'configurations': NativeList([
              NativeEntry('Release', {
                'bundleIdentifier': const NativeValue.found(
                  'a.b',
                  at: 'ios/p.pbxproj:9',
                ),
              }, at: 'ios/p.pbxproj:7'),
              NativeEntry('Debug', {
                'bundleIdentifier': const NativeValue.found('a.b.debug'),
                'swiftVersion': const NativeValue.found('5.0'),
              }),
            ]),
            'flavors': NativeList(const []),
            'permissions': NativeList([
              NativeEntry(
                'android.permission.INTERNET',
                const {},
                at: 'm.xml:6',
              ),
            ]),
          }),
          headings: const {'configurations': 'Configurations'},
        ),
        '### Configurations\n'
        '\n'
        '| Name | Declared at | `bundleIdentifier` | `swiftVersion` |\n'
        '|---|---|---|---|\n'
        '| `Debug` |  | `a.b.debug` | `5.0` |\n'
        '| `Release` | [ios/p.pbxproj:7](../../ios/p.pbxproj#L7) | `a.b` '
        '([ios/p.pbxproj:9](../../ios/p.pbxproj#L9)) |  |\n'
        '\n'
        '### `flavors`\n'
        '\n'
        'None.\n'
        '\n'
        '### `permissions`\n'
        '\n'
        '| Name | Declared at |\n'
        '|---|---|\n'
        '| `android.permission.INTERNET` | [m.xml:6](../../m.xml#L6) |',
      );
    });

    test('groups inside groups get deeper headings', () {
      expect(
        _tables(
          NativeGroup({
            'manifests': NativeGroup({
              'main': NativeGroup({
                'label': const NativeValue.found('App'),
                'permissions': NativeList(const []),
              }),
            }),
          }),
          headings: const {'manifests': 'Manifests'},
        ),
        '### Manifests\n'
        '\n'
        '#### `main`\n'
        '\n'
        '| Setting | Value | Where |\n'
        '|---|---|---|\n'
        '| `label` | `App` |  |\n'
        '\n'
        '##### `permissions`\n'
        '\n'
        'None.',
      );
    });

    test('an entry with parts that are not values keeps them', () {
      final text = _tables(
        NativeGroup({
          'flavors': NativeList([
            NativeEntry('dev', {
              'applicationId': const NativeValue.found('a.dev'),
              'signing': NativeGroup({'key': const NativeValue.found('k')}),
            }),
          ]),
        }),
      );
      expect(text, contains('| `dev` |  | `a.dev` |'));
      expect(text, contains('#### `dev`\n\n##### `signing`\n\n| Setting |'));
      expect(text, contains('| `key` | `k` |  |'));
    });

    test('an empty group is empty', () {
      expect(_tables(NativeGroup(const {})), '');
    });
  });
}
