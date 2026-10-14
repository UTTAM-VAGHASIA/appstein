// Run by mcp_command_test.dart as a separate process, to be stopped or
// killed: `appstein mcp` itself (`runAppstein`) over this process's real
// stdin and stdout, for the project in its first argument, with the fake
// Flutter SDK in its second and the Dart SDK that runs the analysis server
// in its third. It names its own process on stderr first, since `dart` may
// run a script in a child process.

import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';

Future<void> main(List<String> arguments) async {
  final [project, flutterRoot, dartSdk] = arguments;
  stderr.writeln('serving $pid');
  final code = await runAppstein(
    ['--project', project, 'mcp'],
    environment: HostEnvironment(
      os: HostOs.current,
      variables: {'FLUTTER_ROOT': flutterRoot},
      workingDirectory: project,
    ),
    dartSdkPath: dartSdk,
  );
  await stderr.flush();
  exit(code);
}
