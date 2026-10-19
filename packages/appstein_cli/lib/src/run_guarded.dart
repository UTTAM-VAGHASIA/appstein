import 'dart:async';
import 'dart:io';

import 'exit_codes.dart';
import 'failure.dart';
import 'runner.dart';
import 'verify_hook.dart';

/// Runs [body] and makes an error that escapes it, including one raised
/// asynchronously outside its future chain, end the process with exit code
/// [ExitCodes.appsteinFailed] instead of the VM's 255 (spec §15).
///
/// When [arguments] ask for Claude Code's hook mode (`verify --hook claude`)
/// the escaped error is told the hook's way instead: the failure JSON on
/// stdout, the details on stderr, and exit code 0, since a failure of
/// Appstein must never block the agent (spec §9.5). The kind of hook comes
/// from the arguments ([claudeHookKind]), since no input was read here; a Stop
/// hook tells the developer only. The run and this handler
/// share one [HookAnswer], which the body finds as `HookAnswer.current`, so
/// whichever speaks first is the only answer: an error that escapes while the
/// body is still running, and the body's own reply after it, never make two
/// JSON documents or change an exit code already given.
///
/// [body] returns the exit code. It is set on [exitCode], not passed to
/// `exit()`, so output can finish flushing.
Future<void> runGuarded(
  Future<int> Function() body, {
  List<String> arguments = const [],
}) {
  final done = Completer<void>();
  final hook = claudeHookKind(arguments);
  final answer = HookAnswer();
  runZonedGuarded(
    () async {
      final code = await body();
      // An escaped error already decided the exit code; don't undo it.
      if (done.isCompleted) return;
      exitCode = code;
      done.complete();
    },
    (error, stackTrace) {
      try {
        if (hook != null) {
          exitCode = answerHookFailure(
            stdout,
            stderr,
            unexpectedFailure(error, stackTrace),
            answer,
            kind: hook,
          );
        } else {
          exitCode = ExitCodes.appsteinFailed;
          reportCrash(stderr, error, stackTrace);
        }
      } on Object {
        // stderr itself is broken, or the error can't even be described; the
        // exit code is all that is left. A hook reply already given keeps its
        // code, so a late failure never unblocks an exit 2.
        exitCode = hook != null
            ? answer.exitCode ?? ExitCodes.ok
            : ExitCodes.appsteinFailed;
      }
      if (!done.isCompleted) done.complete();
    },
    zoneValues: answer.zoneValues,
  );
  return done.future;
}
