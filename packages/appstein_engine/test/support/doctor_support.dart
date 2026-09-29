import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import 'fake_process_runner.dart';
import 'temp.dart';

/// A doctor context for one check. By default the SDK is Flutter 3.47.5
/// (stable), found through PATH, with an empty environment and a runner
/// that knows no commands.
DoctorContext testContext({
  SdkDetection? sdk,
  String? projectRoot,
  HostEnvironment? environment,
  ProcessRunner? runner,
}) => DoctorContext(
  environment: environment ?? fakeEnvironment({}),
  runner: runner ?? FakeProcessRunner(),
  projectRoot: projectRoot,
  sdk: sdk ?? foundSdk(),
);

/// A successful SDK detection with the given versions.
SdkDetection foundSdk({
  String flutter = '3.47.5',
  String channel = 'stable',
  String root = '/sdk',
  SdkSource source = SdkSource.path,
}) => SdkDetection.found(
  SdkInfo(flutterVersion: flutter, dartVersion: '3.13.4', channel: channel),
  SdkLocation(root: root, source: source),
);
