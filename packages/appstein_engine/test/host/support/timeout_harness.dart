// Run by process_runner_test.dart as a separate process: runs the script in
// its first argument with a 2 s limit and prints what the runner reported.
// The test measures how long this whole process takes to exit.
import 'package:appstein_engine/appstein_engine.dart';

Future<void> main(List<String> arguments) async {
  final result = await const SystemProcessRunner().run(
    arguments.single,
    const [],
    timeout: const Duration(seconds: 2),
  );
  print('timedOut=${result.timedOut}');
  print('stdout=${result.stdout.trim()}');
}
