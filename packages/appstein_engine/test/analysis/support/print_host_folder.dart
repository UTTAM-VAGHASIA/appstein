import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';

/// Prints the folder of the analysis hosts' address files that this process
/// chooses for the project at the first argument, from the real machine
/// (`HostEnvironment.current()`): the test that starts it gives it an
/// environment of its own, to show that the variables change nothing. It
/// only chooses: nothing is made or written.
void main(List<String> arguments) {
  stdout.write(
    chooseAnalysisHostFolder(
      HostEnvironment.current(),
      projectRoot: arguments.single,
    ).folder,
  );
}
