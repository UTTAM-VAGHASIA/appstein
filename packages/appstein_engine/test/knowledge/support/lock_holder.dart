// Run by knowledge_lock_test.dart as a separate process: takes the write
// lock on the folder in its first argument, prints "locked", holds it for
// the milliseconds in its second argument, then exits without releasing
// it, as a crashed writer would. It exits sooner when its stdin closes:
// the test closes it in teardown instead of killing the process (see
// holdLock in knowledge_lock_test.dart for why).
import 'dart:io';

import 'package:appstein_engine/src/knowledge/knowledge_lock.dart';

Future<void> main(List<String> arguments) async {
  await KnowledgeLock.acquire(arguments[0]);
  stdin.listen((_) {}, onDone: () => exit(0));
  stdout.writeln('locked');
  await stdout.flush();
  await Future<void>.delayed(Duration(milliseconds: int.parse(arguments[1])));
  exit(0);
}
