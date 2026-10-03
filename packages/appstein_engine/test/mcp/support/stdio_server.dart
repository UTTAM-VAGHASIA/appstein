// Run by mcp_stdio_test.dart as a separate process: serves the project in
// its first argument over this process's real stdin and stdout, with the
// Flutter SDK in its second argument and the Dart SDK in its third (for
// the analysis), as `appstein mcp` would with the official_mvvm, android
// and ios packs.

import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';

Future<void> main(List<String> arguments) async {
  final [projectRoot, flutterRoot, dartSdk] = arguments;
  final held = HeldAnalyzerCache();
  final server = AppsteinMcpServer(
    stdioMcpChannel(stdin, stdout),
    projectRoot: projectRoot,
    appsteinVersion: '0.1.0-dev',
    dartSdkPath: dartSdk,
    syncFor: () => KnowledgeSync(
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': flutterRoot},
        workingDirectory: projectRoot,
      ),
      appsteinVersion: '0.1.0-dev',
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
      heldCache: held,
    ),
  );
  await server.done;
}
