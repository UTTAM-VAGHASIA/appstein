// Run by run_guarded_test.dart as a separate process. Throws from a timer, so
// the error is outside the future chain that runGuarded awaits.
import 'dart:async';

import 'package:appstein_cli/appstein_cli.dart';

Future<void> main() => runGuarded(() async {
  Timer(Duration.zero, () => throw StateError('async boom'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  return 0;
});
