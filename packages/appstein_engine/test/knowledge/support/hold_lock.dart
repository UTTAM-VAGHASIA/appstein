import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Starts a separate process that holds the lock on [folder] for [ms]
/// milliseconds, and waits until it has it.
Future<Process> holdLock(String folder, int ms) async {
  // Found from the package, not from Directory.current: other test files
  // change the working directory, which is shared by the whole process.
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  );
  final holder = p.join(
    p.dirname(p.dirname(library!.toFilePath())),
    'test',
    'knowledge',
    'support',
    'lock_holder.dart',
  );
  final process = await Process.start(Platform.resolvedExecutable, [
    holder,
    folder,
    '$ms',
  ]);
  // Keep what the holder prints on stderr, so a crashed holder is visible.
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  addTearDown(() async {
    // Ask the holder to exit by closing its stdin, then wait, so the temp
    // folder it locked can be deleted. Killing it is not enough on Windows:
    // `dart` runs the script in a child dartvm process, which holds the
    // lock, and the kill reports `dart` exited while that child still has
    // the file open. On a normal exit the child ends first.
    try {
      await process.stdin.close();
    } on Object {
      // The holder already exited (its hold time ran out).
    }
    await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill();
        return process.exitCode;
      },
    );
  });
  try {
    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line == 'locked')
        .timeout(const Duration(seconds: 60));
  } on Object catch (error) {
    throw StateError(
      'The lock holder never reported "locked" ($error). '
      'Its stderr: $errors',
    );
  }
  return process;
}
