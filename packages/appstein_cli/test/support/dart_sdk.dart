import 'dart:io';

import 'package:path/path.dart' as p;

/// The Dart SDK running the tests. The analyzer reads `dart:` libraries from
/// its `lib/`. The fake Flutter SDK has none, so a run that builds the
/// project's knowledge is given this one.
String get testDartSdk => p.dirname(p.dirname(Platform.resolvedExecutable));
