import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';

Future<void> main(List<String> arguments) async {
  // Setting exitCode (instead of calling exit()) lets stdout finish flushing,
  // which matters on Windows consoles.
  exitCode = await runAppstein(arguments);
}
