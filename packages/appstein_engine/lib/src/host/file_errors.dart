import 'dart:io';

/// Why a file operation failed, for a message: the operating system's own
/// words when it gave any (such as "Access is denied." or "Permission
/// denied"), or else Dart's message (such as a file that isn't valid
/// UTF-8, where there is no OS error).
String fileErrorReason(FileSystemException error) {
  final os = error.osError?.message;
  return os == null || os.isEmpty ? error.message : os;
}
