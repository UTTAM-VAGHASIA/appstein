import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/temp.dart';

final class _RoutesAgain implements MapExtractor {
  const _RoutesAgain();

  @override
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis) => {
    MapFiles.routes: const {'routes': <Object?>[]},
  };
}

final class _SecondPack implements Pack {
  const _SecondPack();

  @override
  String get id => 'second';

  @override
  PackKind get kind => PackKind.stack;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [_RoutesAgain()];

  @override
  LayerRules? get layerRules => null;

  @override
  NativeExtractor? get nativeExtractor => null;
}

void main() {
  test('two extractors writing the same map file is a StateError', () async {
    final app = copyFixtureApp();
    final sync = MapSync(
      environment: fakeEnvironment({}),
      appsteinVersion: '0.1.0-dev',
      packs: const [OfficialMvvmPack(), _SecondPack()],
      runner: FakeProcessRunner(),
    );
    await expectLater(
      sync.build(
        app,
        flutterVersion: '3.47.5',
        flutterRoot: tempDir().path,
        dartSdkPath: testDartSdk,
      ),
      throwsStateError,
    );
  });
}
