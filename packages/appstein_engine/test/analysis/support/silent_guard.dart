// A guard whose server never says anything, for the test of a server that
// is never ready: it names itself as both processes, and ends in order
// when its stdin closes.

import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_guard.dart';

Future<void> main() async {
  stderr.writeln('$analysisGuardSign$pid $pid');
  await stdin.drain<void>();
  stderr.writeln(analysisGuardEnded);
}
