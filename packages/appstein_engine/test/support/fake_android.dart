import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates an Android Studio folder named [name] with a bundled JDK, laid out
/// for this OS, and returns the Android Studio folder.
String fakeStudio(Directory parent, {String name = 'Android Studio'}) {
  final studio = p.join(parent.path, name);
  File(
    p.join(
      studioJdkHome(studio),
      'bin',
      Platform.isWindows ? 'java.exe' : 'java',
    ),
  ).createSync(recursive: true);
  return studio;
}

/// The JDK folder inside an Android Studio folder, for this OS.
String studioJdkHome(String studio) => Platform.isMacOS
    ? p.join(studio, 'Contents', 'jbr', 'Contents', 'Home')
    : p.join(studio, 'jbr');

/// Writes an Android Studio install record, `<parent>/<folder>/.home`, that
/// names the install folder [studio], as Android Studio does on first start.
void writeStudioRecord(String parent, String folder, String studio) {
  final record = Directory(p.join(parent, folder))..createSync(recursive: true);
  File(p.join(record.path, '.home')).writeAsStringSync(studio);
}

/// A skip reason when this Mac or Linux machine has Android Studio in a
/// default folder, which the Java lookup would find. Null otherwise.
String? studioInstalledReason() {
  for (final dir in [
    '/Applications/Android Studio.app',
    '/opt/android-studio',
  ]) {
    if (Directory(dir).existsSync()) {
      return 'Android Studio is installed at $dir on this machine.';
    }
  }
  return null;
}
