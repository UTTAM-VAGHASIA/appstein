@Tags(['integration'])
library;

import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/machine_sdk.dart';

void main() {
  final environment = HostEnvironment.current();

  test('the fixture app with the real flutter and go_router gives the map '
      'the stand-ins give', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final app = copyFixtureApp(stubs: false);
    final sync = KnowledgeSync(
      environment: environment,
      appsteinVersion: 'integration-test',
      packs: const [OfficialMvvmPack()],
    );

    // No packages yet: sync fetches them with this Flutter (go_router comes
    // from pub.dev).
    final first = await sync.run(app, sdk: sdk);
    expect(
      first.map!.packages,
      PackagesAction.fetched,
      reason: first.map!.packagesReason,
    );
    expect(first.map!.skipped, isNull, reason: first.map!.packagesReason);

    for (final name in [
      'features.json',
      'layers.json',
      'routes.json',
      'symbols.json',
    ]) {
      expectGolden(name, readMapBody(app, name));
    }
    // Versions and transitive packages differ from the stand-ins'; the
    // direct packages' kinds, constraints and usages must not.
    final deps = DepsMap.fromJson(readMapBody(app, 'deps.json'));
    final golden = DepsMap.fromJson(
      jsonDecode(goldenText('deps.json')) as Map<String, Object?>,
    );
    for (final name in ['flutter', 'flutter_test', 'go_router']) {
      final real = deps.packages[name]!;
      final stand = golden.packages[name]!;
      expect(real.dependency, stand.dependency, reason: name);
      expect(real.constraint, stand.constraint, reason: name);
      expect(real.usages, stand.usages, reason: name);
    }
    expect(deps.packages['go_router']!.version, startsWith('18.'));

    // The fetch left fresh packages, so the next sync runs nothing and
    // changes nothing.
    final second = await sync.run(app, sdk: sdk);
    expect(
      second.map!.packages,
      PackagesAction.upToDate,
      reason: second.map!.packagesReason,
    );
    expect(second.files.values, everyElement(isFalse));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
