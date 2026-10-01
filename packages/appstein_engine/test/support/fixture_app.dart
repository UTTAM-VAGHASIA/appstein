import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'temp.dart';

/// `test/fixtures/apps`, found from the package itself, not from
/// `Directory.current` (other test files change the working folder).
String get fixtureAppsDir {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  return p.join(
    p.dirname(p.dirname(library.toFilePath())),
    'test',
    'fixtures',
    'apps',
  );
}

/// The Dart SDK running the tests. The analyzer reads `dart:` libraries
/// from its `lib/`.
String get testDartSdk => p.dirname(p.dirname(Platform.resolvedExecutable));

/// Copies the files under [from] into [to], dropping the `.fixture` suffix
/// from their names.
void copyFixtureTree(String from, String to) {
  for (final entity in Directory(from).listSync(recursive: true)) {
    if (entity is! File) continue;
    var relative = p.relative(entity.path, from: from);
    if (relative.endsWith('.fixture')) {
      relative = relative.substring(0, relative.length - '.fixture'.length);
    }
    final target = File(p.join(to, relative))
      ..parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

/// Copies the fixture app into a new temp folder, as `mvvm app`, and
/// returns that folder.
///
/// With [stubs], the stand-in `flutter`, `flutter_test` and `go_router`
/// packages are copied beside it into `stubs/`, and the app gets a lock file
/// and a package config that point at them. Its packages then count as
/// fresh for Flutter [flutterVersion], so it analyzes like a real app
/// without a Flutter SDK or the network. Without [stubs], only the app is
/// copied, for a real `flutter pub get`.
String copyFixtureApp({bool stubs = true, String flutterVersion = '3.47.5'}) {
  final work = tempDir().path;
  final app = p.join(work, 'mvvm app');
  copyFixtureTree(p.join(fixtureAppsDir, 'mvvm_app'), app);
  if (!stubs) return app;
  final stubFolder = p.join(work, 'stubs');
  copyFixtureTree(p.join(fixtureAppsDir, 'stubs'), stubFolder);
  File(
    p.join(stubFolder, 'pubspec.lock'),
  ).copySync(p.join(app, 'pubspec.lock'));
  writeStubPackages(
    app,
    packages: const ['flutter', 'flutter_test', 'go_router'],
    flutterVersion: flutterVersion,
  );
  return app;
}

/// Makes [project] count as having fresh packages:
/// - `.dart_tool/package_config.json` maps the project's own package (its
///   pubspec `name:`) and each of [packages], which live in `../stubs/`;
/// - `.dart_tool/version` is [flutterVersion];
/// - `pubspec.yaml` gets an older time than `pubspec.lock` (created empty
///   when missing) and the package config.
void writeStubPackages(
  String project, {
  List<String> packages = const [],
  String flutterVersion = '3.47.5',
}) {
  final name = RegExp(r'^name:\s*(\S+)', multiLine: true)
      .firstMatch(File(p.join(project, 'pubspec.yaml')).readAsStringSync())!
      .group(1)!;
  Map<String, Object?> entry(String package, String rootUri) => {
    'name': package,
    'rootUri': rootUri,
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  };
  final config = File(p.join(project, '.dart_tool', 'package_config.json'))
    ..parent.createSync(recursive: true);
  config.writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        entry(name, '../'),
        for (final package in packages) entry(package, '../../stubs/$package'),
      ],
      'generator': 'pub',
    }),
  );
  File(
    p.join(project, '.dart_tool', 'version'),
  ).writeAsStringSync(flutterVersion);
  final lock = File(p.join(project, 'pubspec.lock'));
  if (!lock.existsSync()) lock.writeAsStringSync('packages: {}\n');
  final now = DateTime.now();
  File(
    p.join(project, 'pubspec.yaml'),
  ).setLastModifiedSync(now.subtract(const Duration(hours: 1)));
  lock.setLastModifiedSync(now);
  config.setLastModifiedSync(now);
}

/// The 1-based line of the first line of [file] (relative to [project],
/// with `/`) that contains [text]. Tests use it instead of hard-coding line
/// numbers.
int lineOf(String project, String file, String text) {
  final lines = File(
    p.joinAll([project, ...file.split('/')]),
  ).readAsLinesSync();
  final index = lines.indexWhere((line) => line.contains(text));
  if (index < 0) throw StateError('"$text" is not in $file');
  return index + 1;
}

/// The body of `.appstein/map/<name>` in [project], without its `meta`.
Map<String, Object?> readMapBody(String project, String name) =>
    (jsonDecode(
            File(p.join(project, '.appstein', 'map', name)).readAsStringSync(),
          )
          as Map<String, Object?>)
      ..remove('meta');

/// The text of the golden for the map file [name].
String goldenText(String name) => File(
  p.join(fixtureAppsDir, 'goldens', '$name.golden'),
).readAsStringSync().replaceAll('\r\n', '\n');

/// Checks [body] (a map file without its `meta`) against the golden file
/// `test/fixtures/apps/goldens/<name>.golden`.
///
/// With the environment variable `APPSTEIN_UPDATE_GOLDENS=1` it writes the
/// golden instead. That is the one time a test writes into the repo: review
/// the diff before committing it (see the developer guide's testing page).
void expectGolden(String name, Map<String, Object?> body) {
  final golden = File(p.join(fixtureAppsDir, 'goldens', '$name.golden'));
  final actual = canonicalJson(body);
  if (Platform.environment['APPSTEIN_UPDATE_GOLDENS'] == '1') {
    golden
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(actual);
    return;
  }
  expect(
    golden.existsSync(),
    isTrue,
    reason:
        'No golden at ${golden.path}. Run the test with '
        'APPSTEIN_UPDATE_GOLDENS=1 to create it, then review it.',
  );
  expect(
    actual,
    goldenText(name),
    reason:
        'The map differs from ${golden.path}. If the change is intended, '
        'rerun with APPSTEIN_UPDATE_GOLDENS=1 and review the diff.',
  );
}
