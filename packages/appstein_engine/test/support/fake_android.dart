import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

/// Creates an Android Studio folder named [name] with a bundled JDK, laid out
/// for [os] (this OS by default), and returns the Android Studio folder. On
/// macOS the folder is the `.app` bundle.
String fakeStudio(
  Directory parent, {
  String name = 'Android Studio',
  HostOs? os,
}) {
  final target = os ?? HostOs.current;
  final studio = p.join(parent.path, name);
  File(
    p.join(
      studioJdkHome(studio, os: target),
      'bin',
      target == HostOs.windows ? 'java.exe' : 'java',
    ),
  ).createSync(recursive: true);
  return studio;
}

/// The JDK folder inside an Android Studio folder, for [os] (this OS by
/// default), for Android Studio 2022 and newer.
String studioJdkHome(String studio, {HostOs? os}) =>
    (os ?? HostOs.current) == HostOs.macos
    ? p.join(studio, 'Contents', 'jbr', 'Contents', 'Home')
    : p.join(studio, 'jbr');

/// Writes a macOS `Contents/Info.plist` into the app [bundle], as XML, with
/// [version] as `CFBundleShortVersionString` when it is set. With [toolbox],
/// it has the `JetBrainsToolboxApp` key a JetBrains Toolbox launcher has.
void writeInfoPlist(String bundle, {String? version, bool toolbox = false}) {
  File(p.join(bundle, 'Contents', 'Info.plist'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<plist version="1.0">',
        '<dict>',
        if (version != null) ...[
          '  <key>CFBundleShortVersionString</key>',
          '  <string>$version</string>',
        ],
        if (toolbox) ...[
          '  <key>JetBrainsToolboxApp</key>',
          '  <string>/Users/me/Applications/Android Studio.app</string>',
        ],
        '</dict>',
        '</plist>',
        '',
      ].join('\n'),
    );
}

/// Writes an Android Studio install record, `<parent>/<folder>/.home`, that
/// names the install folder [studio], as Android Studio does on first start.
void writeStudioRecord(String parent, String folder, String studio) {
  final record = Directory(p.join(parent, folder))..createSync(recursive: true);
  File(p.join(record.path, '.home')).writeAsStringSync(studio);
}

/// A skip reason when this Mac or Linux machine has Android Studio where the
/// Java lookup looks by default, so it would find the real one. Null
/// otherwise. On macOS it checks the `Android Studio*.app` bundles directly
/// in `/Applications` and `~/Applications`.
String? studioInstalledReason() {
  if (Directory('/opt/android-studio').existsSync()) {
    return 'Android Studio is installed at /opt/android-studio on this '
        'machine.';
  }
  if (!Platform.isMacOS) return null;
  final home = Platform.environment['HOME'];
  for (final folder in [
    '/Applications',
    if (home != null) p.join(home, 'Applications'),
  ]) {
    final dir = Directory(folder);
    if (!dir.existsSync()) continue;
    for (final entry in dir.listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is Directory &&
          name.startsWith('Android Studio') &&
          name.endsWith('.app')) {
        return 'Android Studio is installed at ${entry.path} on this machine.';
      }
    }
  }
  return null;
}
