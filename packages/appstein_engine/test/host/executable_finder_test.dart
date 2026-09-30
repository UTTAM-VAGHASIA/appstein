import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('finds an executable in a PATH folder with spaces', () {
    final dir = tempDir();
    final exe = fakeExecutable(dir, 'mytool');
    final env = fakeEnvironment({'PATH': dir.path, 'PATHEXT': defaultPathExt});
    expect(findExecutable('mytool', env), exe);
  });

  test('skips empty and quoted PATH entries', () {
    final dir = tempDir();
    final exe = fakeExecutable(dir, 'mytool');
    final value = Platform.isWindows ? ';;"${dir.path}";' : '::${dir.path}:';
    final env = fakeEnvironment({'PATH': value, 'PATHEXT': defaultPathExt});
    expect(findExecutable('mytool', env), exe);
  });

  test('returns null when the tool is missing', () {
    final env = fakeEnvironment({
      'PATH': tempDir().path,
      'PATHEXT': defaultPathExt,
    });
    expect(findExecutable('mytool', env), isNull);
  });

  test('on Windows, follows PATHEXT order', () {
    final dir = tempDir();
    File(p.join(dir.path, 'mytool.cmd')).writeAsStringSync('@echo off');
    final bat = File(p.join(dir.path, 'mytool.bat'))
      ..writeAsStringSync('@echo off');
    final env = fakeEnvironment({'PATH': dir.path, 'PATHEXT': '.BAT;.CMD'});
    expect(findExecutable('mytool', env), bat.path);
  }, testOn: 'windows');

  test('on POSIX, ignores files without the executable bit', () {
    final dir = tempDir();
    File(p.join(dir.path, 'mytool')).writeAsStringSync('#!/bin/sh');
    expect(
      findExecutable('mytool', fakeEnvironment({'PATH': dir.path})),
      isNull,
    );
  }, testOn: '!windows');

  test('findAllExecutables lists every match, in PATH order', () {
    final first = tempDir();
    final second = tempDir();
    final a = fakeExecutable(first, 'mytool');
    final b = fakeExecutable(second, 'mytool');
    final separator = Platform.isWindows ? ';' : ':';
    final env = fakeEnvironment({
      'PATH': '${second.path}$separator${first.path}',
      'PATHEXT': defaultPathExt,
    });
    expect(findAllExecutables('mytool', env), [b, a]);
    expect(findExecutable('mytool', env), b);
  });

  test('findAllExecutables is empty when the tool is missing', () {
    final env = fakeEnvironment({
      'PATH': tempDir().path,
      'PATHEXT': defaultPathExt,
    });
    expect(findAllExecutables('mytool', env), isEmpty);
  });

  test('on Windows, findAllExecutables lists each PATHEXT match in a '
      'folder', () {
    final dir = tempDir();
    final cmd = File(p.join(dir.path, 'mytool.cmd'))
      ..writeAsStringSync('@echo off');
    final bat = File(p.join(dir.path, 'mytool.bat'))
      ..writeAsStringSync('@echo off');
    final env = fakeEnvironment({'PATH': dir.path, 'PATHEXT': '.BAT;.CMD'});
    expect(findAllExecutables('mytool', env), [bat.path, cmd.path]);
  }, testOn: 'windows');
}
