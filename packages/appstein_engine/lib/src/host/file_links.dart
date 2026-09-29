import 'dart:io';

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
