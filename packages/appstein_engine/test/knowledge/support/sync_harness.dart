import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_process_runner.dart';
import '../../support/fake_sdk.dart';
import '../../support/flutter_fixtures.dart';
import '../../support/temp.dart';

/// A fake Flutter SDK of [version] with its toolchain files, in a temp
/// folder. The toolchain fixtures exist for 3.47.5 and 3.44.9.
String fakeFlutter({String version = '3.47.5'}) {
  final sdk = createFakeSdk(
    p.join(tempDir().path, 'flutter'),
    flutter: version,
  );
  addToolchainFiles(sdk, version);
  return sdk;
}

/// The `flutter` launcher of the SDK at [sdk], as `flutter pub get` runs it.
String flutterCommand(String sdk) =>
    p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');

/// `KnowledgeSync` as `appstein sync` builds it, on the Flutter SDK at
/// [flutterRoot], with [runner] for `flutter pub get` and a fixed clock.
KnowledgeSync knowledgeSync({
  required String flutterRoot,
  required FakeProcessRunner runner,
  List<Pack> packs = const [OfficialMvvmPack()],
  String baseline = '3.16',
  String appsteinVersion = '0.1.0-dev',
  bool analyzerCache = true,
  DeltaCollector? deltaCollector,
  Duration lockTimeout = const Duration(seconds: 10),
  bool packageSkills = true,
  HeldAnalyzerCache? heldCache,
}) => KnowledgeSync(
  environment: fakeEnvironment({'FLUTTER_ROOT': flutterRoot}),
  appsteinVersion: appsteinVersion,
  packs: packs,
  runner: runner,
  clock: () => DateTime.utc(2026, 10, 1, 9),
  baseline: baseline,
  analyzerCache: analyzerCache,
  deltaCollector: deltaCollector,
  lockTimeout: lockTimeout,
  packageSkills: packageSkills,
  heldCache: heldCache,
);

/// The text of every file under [project]'s `.appstein/`, by its path
/// there with `/`, except the lock file.
Map<String, String> knowledgeFiles(String project) {
  final folder = p.join(project, '.appstein');
  return {
    for (final entity in Directory(folder).listSync(recursive: true))
      if (entity is File && p.basename(entity.path) != '.lock')
        p.split(p.relative(entity.path, from: folder)).join('/'): entity
            .readAsStringSync(),
  };
}

/// Every file under [project]'s `.appstein/` and `.dart_tool/appstein/`,
/// with its text (Latin-1, so any bytes compare) and modified time, to check
/// that nothing was written.
Map<String, (String, DateTime)> snapshot(String project) => {
  for (final folder in [
    p.join(project, '.appstein'),
    p.join(project, '.dart_tool', 'appstein'),
  ])
    if (Directory(folder).existsSync())
      for (final entity in Directory(folder).listSync(recursive: true))
        if (entity is File)
          entity.path: (
            latin1.decode(entity.readAsBytesSync()),
            entity.lastModifiedSync(),
          ),
};
