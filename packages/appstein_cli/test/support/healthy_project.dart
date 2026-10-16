import 'dart:convert';
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dart_sdk.dart';

/// Makes the project at [project] (which has a `pubspec.yaml`) a healthy one:
/// its packages count as fresh, so the knowledge can be built without
/// `flutter pub get`, and its docs are rendered first, as `appstein docs`
/// does, so none is stale. A run on it finds only what a test adds, and
/// prints the summary alone. [sdk] is the fake Flutter SDK the tests use.
Future<void> createHealthyProject({
  required String project,
  required String sdk,
}) async {
  File(p.join(project, 'lib', 'main.dart'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('void main() {}\n');
  File(p.join(project, '.dart_tool', 'package_config.json'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'my_app',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
        ],
        'generator': 'pub',
      }),
    );
  File(p.join(project, '.dart_tool', 'version')).writeAsStringSync('3.47.5');
  File(p.join(project, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
  final now = DateTime.now();
  File(
    p.join(project, 'pubspec.yaml'),
  ).setLastModifiedSync(now.subtract(const Duration(hours: 1)));
  File(p.join(project, 'pubspec.lock')).setLastModifiedSync(now);
  File(
    p.join(project, '.dart_tool', 'package_config.json'),
  ).setLastModifiedSync(now);

  const config = AppsteinConfig();
  final packs = packsFor(config);
  final outcome = await runDocs(
    projectRoot: project,
    config: config,
    packs: packs,
    sync: KnowledgeSync(
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': sdk},
        workingDirectory: project,
      ),
      appsteinVersion: appsteinVersion,
      packs: packs,
      baseline: config.delta.baseline,
      agents: config.integrations.agents,
      packageSkills: false,
    ),
    check: false,
    dartSdkPath: testDartSdk,
  );
  expect(outcome, isA<DocsDone>());
}
