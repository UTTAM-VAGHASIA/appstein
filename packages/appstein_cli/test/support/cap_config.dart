import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes the `appstein.yaml` of [project] with the cap of a fast run
/// (`verify.fast_timeout_seconds`) at [seconds].
void writeCap(String project, int seconds) => File(
  p.join(project, 'appstein.yaml'),
).writeAsStringSync('appstein: 1\nverify:\n  fast_timeout_seconds: $seconds\n');

/// A cap a cold start of the analysis host or server on a busy machine can't
/// reach, for tests of the host and the server that are not about the cap.
const waitAsLongAsItTakes = 600;
