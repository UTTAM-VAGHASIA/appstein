import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// This build's version. It must match `version:` in pubspec.yaml; a test
/// checks that.
const appsteinVersion = '0.1.0-dev';

/// The text `appstein --version` prints: the Appstein version, the protocol
/// version and the supported Flutter range.
String versionText() => [
  'appstein $appsteinVersion',
  'protocol $protocolVersion',
  'flutter >=$minSupportedFlutter (built for up to $newestKnownFlutterMinor)',
].join('\n');
