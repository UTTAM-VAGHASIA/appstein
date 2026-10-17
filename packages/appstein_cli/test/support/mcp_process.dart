// Run by mcp_command_test.dart as a separate process, to be stopped:
// `appstein mcp` itself (`runAppstein`) over this process's real stdin and
// stdout, for the project in its first argument, with the fake Flutter SDK
// in its second, the Dart SDK that runs the analysis server in its third,
// the analysis server's cache folder in its fourth and the folder of the
// analysis hosts' address files in its fifth. It names its own process on
// stderr first, since `dart` may run a script in a child process.

import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';

Future<void> main(List<String> arguments) async {
  final [project, flutterRoot, dartSdk, cache, hosts] = arguments;
  stderr.writeln('serving $pid');
  final code = await runAppstein(
    ['--project', project, 'mcp'],
    environment: HostEnvironment(
      os: HostOs.current,
      variables: {
        'FLUTTER_ROOT': flutterRoot,
        analysisCacheVariable: cache,
        analysisHostFolderVariable: hosts,
      },
      workingDirectory: project,
    ),
    dartSdkPath: dartSdk,
  );
  await stderr.flush();
  exit(code);
}
