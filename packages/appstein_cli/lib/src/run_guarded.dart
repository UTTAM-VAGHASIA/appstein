import 'dart:async';
import 'dart:io';

import 'exit_codes.dart';
import 'runner.dart';

/// Runs [body] and makes an error that escapes it, including one raised
/// asynchronously outside its future chain, end the process with exit code
/// [ExitCodes.appsteinFailed] instead of the VM's 255 (spec §15).
///
/// [body] returns the exit code. It is set on [exitCode], not passed to
/// `exit()`, so output can finish flushing.
Future<void> runGuarded(Future<int> Function() body) {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      final code = await body();
      // An escaped error already decided the exit code; don't undo it.
      if (done.isCompleted) return;
      exitCode = code;
      done.complete();
    },
    (error, stackTrace) {
      exitCode = ExitCodes.appsteinFailed;
      try {
        reportCrash(stderr, error, stackTrace);
      } on Object {
        // stderr itself is broken; the exit code is all that is left.
      }
      if (!done.isCompleted) done.complete();
    },
  );
  return done.future;
}
