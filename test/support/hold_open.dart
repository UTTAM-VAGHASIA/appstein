// A process that does nothing until its input closes, for tests that need a
// child process to find in the process list.

import 'dart:io';

Future<void> main() async {
  await stdin.drain<void>();
}
