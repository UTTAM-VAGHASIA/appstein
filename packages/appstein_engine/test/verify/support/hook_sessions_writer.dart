// Run by hook_sessions_test.dart as a separate process: saves the record of
// session `s1` in the project in its first argument, as many times as its
// third argument says, each time with a fingerprint of the form
// `<tag>-<number>` (its second argument is the tag). It waits long for the
// lock, so a save that comes back false is a record that could not be
// written, and prints how many there were.
//
// It prints `ready` once it is started and waits for a line on stdin before it
// saves, so the test can start every writer first and let them all go at the
// same moment: their saves then overlap, and a save without the lock fails the
// test every time. It imports only the class it uses, not the engine's
// library, so it does not compile the analyzer.
import 'dart:io';

import 'package:appstein_engine/src/verify/hook_sessions.dart';

Future<void> main(List<String> arguments) async {
  final records = HookSessions(
    arguments[0],
    lockTimeout: const Duration(seconds: 30),
  );
  stdout.writeln('ready');
  await stdout.flush();
  stdin.readLineSync(); // The "go" line.
  var failed = 0;
  for (var i = 0; i < int.parse(arguments[2]); i++) {
    if (!await records.saveFingerprint('s1', '${arguments[1]}-$i')) failed++;
  }
  stdout.writeln('failed $failed');
  await stdout.flush();
}
