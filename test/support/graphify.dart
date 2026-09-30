import 'dart:io';

import 'package:path/path.dart' as p;

/// A Python that can import graphify, for the graph check's tests, or null
/// when there is none.
///
/// It tries `APPSTEIN_GRAPHIFY_PYTHON` (CI sets it), then the interpreter
/// this repo's `graphify-out/.graphify_python` names, which graphify writes
/// on each `/graphify` run, and takes the first that can import graphify.
final String? graphifyPython = _findGraphifyPython();

String? _findGraphifyPython() {
  final recorded = File(p.join('graphify-out', '.graphify_python'));
  final fromEnvironment = Platform.environment['APPSTEIN_GRAPHIFY_PYTHON'];
  final candidates = [
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) fromEnvironment,
    if (recorded.existsSync()) recorded.readAsStringSync().trim(),
  ];
  for (final python in candidates) {
    try {
      if (Process.runSync(python, ['-c', 'import graphify']).exitCode == 0) {
        return python;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// The `skip:` value for tests that need graphify: false when a
/// [graphifyPython] exists, or else the reason for skipping.
///
/// With `APPSTEIN_REQUIRE_GRAPHIFY=1` (CI sets it) nothing is skipped, so a
/// missing graphify fails the tests instead of letting them pass unrun.
Object get skipWithoutGraphify {
  if (graphifyPython != null) return false;
  if (Platform.environment['APPSTEIN_REQUIRE_GRAPHIFY'] == '1') return false;
  return 'no Python with graphify (see docs/guide/testing.md)';
}
