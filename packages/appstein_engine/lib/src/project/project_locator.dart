import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns the nearest folder at or above [start] that contains
/// `pubspec.yaml`, or null when there is none.
String? findProjectRoot(String start) {
  var dir = p.normalize(p.absolute(start));
  while (true) {
    if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}
