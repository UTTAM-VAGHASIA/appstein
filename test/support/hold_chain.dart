import 'dart:convert';
import 'dart:io';

/// A chain of processes, each the child of the one before:
/// `dart hold_chain.dart <levels>` starts this script again with one level
/// fewer, until the last, which starts nothing. Each says "started" on
/// stdout once every process under it has started, then waits until its
/// input closes; it then closes its child's input, waits for it and ends.
///
/// With 3 levels a test gets a run, a "guard" under it and a Dart "server"
/// under that, as a terminal `appstein verify` has, made by this script
/// itself and not by how `dart` runs a script (on Windows `dart.exe` hands
/// it to a `dartvm.exe` child; on macOS the process started is the VM).
Future<void> main(List<String> args) async {
  final levels = args.isEmpty ? 1 : int.parse(args.single);
  Process? child;
  if (levels > 1) {
    child = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      '${levels - 1}',
    ]);
    // Its stderr is not read; it writes none.
    await child.stdout
        .transform(utf8.decoder)
        .firstWhere((text) => text.contains('started'));
  } else {
    // A moment to load, so the last one has memory to count.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  stdout.writeln('started');
  await stdout.flush();
  await stdin.drain<void>();
  if (child != null) {
    await child.stdin.close();
    await child.exitCode;
  }
}
