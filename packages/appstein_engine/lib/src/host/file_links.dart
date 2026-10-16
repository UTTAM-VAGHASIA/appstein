import 'dart:io';

import 'package:path/path.dart' as p;

/// Follows symbolic links and Windows junctions in [path] to the real
/// location. Returns [path] unchanged when it can't be resolved.
String resolveLinks(String path) {
  try {
    return FileSystemEntity.isDirectorySync(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// The real location of the folder [folder], with links and junctions
/// followed, when it is somewhere else than [folder]; null when it is the
/// same, and when [folder] does not exist or can't be resolved.
///
/// A tool that resolves links names a file under it by that real location:
/// `flutter test` does, so on macOS, whose temp folder `/var/…` is a link to
/// `/private/var/…`, a project there has its files named under
/// `/private/var/…`. [pathFromRoot] takes it as a second form of the root.
String? realFolder(String folder) {
  try {
    if (!Directory(folder).existsSync()) return null;
    final real = p.normalize(Directory(folder).resolveSymbolicLinksSync());
    return p.equals(real, folder) ? null : real;
  } on FileSystemException {
    return null;
  }
}

/// [text] without each of [folders] where it starts a path in it, as a
/// file URI (`file:///…/`) or as a path with `/` (`…/`), so what is left is
/// the path from that folder.
///
/// The longest form goes first: on macOS the root `/var/…/app` is the end of
/// its real location `/private/var/…/app`, and taking the shorter out first
/// would leave `/private` behind.
String withoutFolders(String text, Iterable<String> folders) {
  final forms = [
    for (final folder in folders) ...[
      '${Uri.file(folder)}/',
      '${folder.replaceAll(r'\', '/')}/',
    ],
  ]..sort((a, b) => b.length.compareTo(a.length));
  var result = text;
  for (final form in forms) {
    result = result.replaceAll(form, '');
  }
  return result;
}

/// [path] (absolute, or relative to [root]) from the folder [root], with `/`
/// on every system; null when it is outside [root].
///
/// A path under [realRoot], the real location of [root] that [realFolder]
/// gives, is inside too: [root] reached another way. The longer of the two
/// is asked first, so a path is named from the deeper one when one holds
/// the other.
String? pathFromRoot(String path, String root, {String? realRoot}) {
  final absolute = p.normalize(p.absolute(root, path));
  final folders = [root, ?realRoot]
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final folder in folders) {
    if (p.isWithin(folder, absolute)) {
      return p.split(p.relative(absolute, from: folder)).join('/');
    }
  }
  return null;
}
