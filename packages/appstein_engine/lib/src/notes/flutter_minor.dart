/// A Flutter major and minor version, such as 3.47.
typedef FlutterMinor = ({int major, int minor});

final _leadingMinor = RegExp(r'^(\d+)\.(\d+)');

/// The major and minor version at the start of [version] (such as
/// `3.47.5`, `3.48.0-0.1.pre` or `3.47`), or null when it doesn't start with
/// two numbers.
FlutterMinor? flutterMinorOf(String version) {
  final match = _leadingMinor.firstMatch(version);
  if (match == null) return null;
  return (major: int.parse(match[1]!), minor: int.parse(match[2]!));
}

/// Compares two Flutter minor versions, so 3.9 comes before 3.10.
int compareFlutterMinors(FlutterMinor a, FlutterMinor b) => a.major != b.major
    ? a.major.compareTo(b.major)
    : a.minor.compareTo(b.minor);
