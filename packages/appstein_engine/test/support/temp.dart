import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temporary folder whose path contains a space and a non-ASCII
/// character, and deletes it after the test.
///
/// Paths like `C:\Users\Jöhn Doe\my app` must work everywhere (spec §4,
/// principle 10), so every file-system test uses this.
Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('appstein tëst ');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Creates a fake executable named [name] in [dir] that prints [output], and
/// returns its path. On Windows it is `name.bat`.
String fakeExecutable(Directory dir, String name, {String output = 'fake'}) {
  if (Platform.isWindows) {
    final file = File(p.join(dir.path, '$name.bat'))
      ..writeAsStringSync('@echo off\r\necho $output\r\n');
    return file.path;
  }
  final file = File(p.join(dir.path, name))
    ..writeAsStringSync('#!/bin/sh\necho "$output"\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A [HostEnvironment] with only [variables], for the real OS unless [os] is
/// given. Pass a fake [os] only to tests that touch no files.
HostEnvironment fakeEnvironment(
  Map<String, String> variables, {
  HostOs? os,
  String? workingDirectory,
}) => HostEnvironment(
  os: os ?? HostOs.current,
  // No lib code reads ProgramFiles any more (Flutter doesn't look in the
  // default Windows Studio folder), but a fake value keeps any future lookup
  // there from finding the real machine's Android Studio. Tests that expect
  // "no FVM pin" also assume no `.fvmrc` exists above the system temp folder.
  variables: {
    'ProgramFiles': r'Z:\appstein-test-no-program-files',
    ...variables,
  },
  workingDirectory: workingDirectory ?? Directory.systemTemp.path,
);

/// The PATHEXT value Windows uses by default, for fake environments.
const defaultPathExt = '.COM;.EXE;.BAT;.CMD';
