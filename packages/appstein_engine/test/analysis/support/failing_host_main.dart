// A stand-in for an analysis host that could not start, as the engine's
// tests start it: it leaves the reason it is given in the failure file beside
// the project's address file, as `runAnalysisHost` does (whole, through a
// file beside it, in a folder it gives a mode first, off Windows), and ends,
// having written no address. Its arguments are the folder of the address
// file, the folder's mode (`700`, as the host gives it, or another to make
// it one a client must not trust), the reason and, last (the client adds it),
// the project's folder.

import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_host.dart';
import 'package:appstein_engine/src/analysis/analysis_server.dart';

Future<void> main(List<String> arguments) async {
  final [folder, mode, why, projectRoot] = arguments;
  final failure = analysisHostFailureFile(
    analysisHostAddressFile(folder, projectRoot),
  );
  await Directory(folder).create(recursive: true);
  if (!Platform.isWindows && !await setFileMode(mode, folder)) exit(1);
  final beside = File('$failure.$pid.tmp');
  await beside.writeAsString(why, flush: true);
  await beside.rename(failure);
  exit(0);
}
