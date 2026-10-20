import 'dart:io';

import 'package:path/path.dart' as p;

import 'warm_verify.dart';

/// The file at [relative] (a path from the root with `/`) in the project at
/// [project].
File projectFile(String project, String relative) =>
    File(p.joinAll([project, ...relative.split('/')]));

/// A Dart file of a project that a measurement edits to add an error and puts
/// back: its text is read when this is made.
final class EditedFile {
  /// Reads the file at [relative] of the project at [project].
  EditedFile(String project, String relative)
    : _file = projectFile(project, relative) {
    _original = _file.readAsStringSync();
  }

  final File _file;
  late final String _original;

  /// Adds the error of edit [n] ([editWithError]: a size and a line of its
  /// own) and returns the line it is on.
  int addError(int n) {
    final edit = editWithError(_original, n);
    _file.writeAsStringSync(edit.text);
    return edit.line;
  }

  /// Puts the file back as it was.
  void restore() => _file.writeAsStringSync(_original);
}
