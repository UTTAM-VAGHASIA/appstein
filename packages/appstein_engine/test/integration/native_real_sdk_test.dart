@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/machine_sdk.dart';
import '../support/temp.dart';

void main() {
  final environment = HostEnvironment.current();

  test('a new app from the real flutter create gives the native.json the '
      'template fixture gives', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final work = tempDir().path;
    final flutter = p.join(
      sdk.location!.root,
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );
    // The folder name has no space: `flutter create` names the project
    // after it unless told otherwise, and the parent's path already has a
    // space and a non-ASCII character.
    final created = await const SystemProcessRunner().run(
      flutter,
      [
        'create',
        '--no-pub',
        '--platforms=android,ios',
        '--org',
        'dev.sample',
        '--project-name',
        'probe_app',
        'native_app',
      ],
      workingDirectory: work,
      timeout: const Duration(minutes: 3),
    );
    expect(created.ok, isTrue, reason: '${created.stdout}\n${created.stderr}');
    final app = p.join(work, 'native_app');

    // The first sync fetches the packages, which writes Package.swift.
    final report = await KnowledgeSync(
      environment: environment,
      appsteinVersion: 'integration-test',
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
    ).run(app, sdk: sdk);
    expect(report.map!.skipped, isNull, reason: report.map!.packagesReason);
    expect(report.native!.errors, isEmpty);

    final body = readMapBody(app, 'native.json');
    final native = NativeConfig.fromJson(body);
    NativeValue value(List<String> path) => native.lookup(path)! as NativeValue;

    // True on Flutter 3.44 and 3.47 alike.
    expect(value(['android', 'buildLanguage']).value, 'kts');
    expect(
      value(['android', 'app', 'minSdk']).expression,
      'flutter.minSdkVersion',
    );
    expect(value(['android', 'app', 'minSdk']).resolvedFrom, 'flutter');
    expect(value(['android', 'settings', 'agp']).status, NativeStatus.found);
    expect(value(['android', 'gradle', 'version']).status, NativeStatus.found);
    expect(
      [
        for (final entry
            in (native.lookup(['ios', 'xcode', 'configurations'])!
                    as NativeList)
                .entries)
          entry.name,
      ],
      ['Debug', 'Profile', 'Release'],
    );
    expect(
      value([
        'ios',
        'xcode',
        'configurations',
        'Release',
        'deploymentTarget',
      ]).status,
      NativeStatus.found,
    );
    expect(
      value(['ios', 'generatedPackage', 'iosVersion']).status,
      NativeStatus.found,
    );
    final swiftPm = value(['ios', 'swiftPackageManager', 'enabled']);
    expect(swiftPm.status, NativeStatus.found);

    // `plugins` follows the generated file: only a file that depends on
    // FlutterFramework (SwiftPM in effect) lists the plugins.
    const packageAt =
        'ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/'
        'Package.swift';
    final package = File(p.join(app, packageAt));
    final hasFlutterFramework =
        package.existsSync() &&
        RegExp(
          r'\.package\(\s*name:\s*"FlutterFramework"',
        ).hasMatch(package.readAsStringSync());
    final plugins = value(['ios', 'generatedPackage', 'plugins']);
    if (hasFlutterFramework) {
      expect(plugins.toJson(), {
        'at': packageAt,
        'status': 'found',
        'value': <Object?>[],
      });
    } else {
      expect(plugins.status, NativeStatus.unknown);
    }

    if (sdk.info!.flutterVersion != '3.47.5') return;
    if (swiftPm.resolvedFrom != 'default') {
      markTestSkipped(
        'SwiftPM is set on this machine (${swiftPm.resolvedFrom}), so '
        'native.json differs from the golden there.',
      );
      return;
    }

    // The golden's Package.swift was written on Windows: no FlutterFramework,
    // so `plugins` is unknown. A Mac with Xcode 15 or later writes it with
    // FlutterFramework, and then `plugins` is a found, empty list (the app
    // has no plugins). Which one applies is decided by the generated file.
    if (!hasFlutterFramework) {
      expectGolden('native.json', body);
      return;
    }
    final golden =
        jsonDecode(goldenText('native.json')) as Map<String, Object?>;
    final generated = ((golden['ios']! as Map)['generatedPackage']! as Map)
        .cast<String, Object?>();
    expect(generated['plugins'], containsPair('status', 'unknown'));
    generated['plugins'] = {
      'at': packageAt,
      'status': 'found',
      'value': <Object?>[],
    };
    expect(canonicalJson(body), canonicalJson(golden));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
