import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates an Android Studio folder with a bundled JDK, laid out for this OS,
/// and returns the Android Studio folder.
String fakeStudio(Directory parent) {
  final studio = p.join(parent.path, 'Android Studio');
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
