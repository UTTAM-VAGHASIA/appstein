import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes [files] files into `build/` of the app at [app], the way a Flutter
/// app's build folder is crowded: nested folders, at most 50 files in each,
/// most of them binary intermediates. Every [dartEvery]th file is a Dart
/// file (the analysis reads those). Returns how many Dart files it wrote.
///
/// Nothing is written for 0 files. The names never start with a dot, since
/// the analysis server leaves such folders out.
int writeLargeBuild(String app, {required int files, int dartEvery = 20}) {
  var dart = 0;
  for (var i = 0; i < files; i++) {
    final folder = p.join(
      app,
      'build',
      'app',
      'part_${i ~/ 2500}',
      'dir_${(i ~/ 50) % 50}',
    );
    final isDart = i % dartEvery == 0;
    if (i % 50 == 0) Directory(folder).createSync(recursive: true);
    File(p.join(folder, 'file_$i.${isDart ? 'dart' : 'bin'}'))
      ..createSync()
      ..writeAsStringSync(isDart ? 'const int generated$i = $i;\n' : 'x$i\n');
    if (isDart) dart++;
  }
  return dart;
}
