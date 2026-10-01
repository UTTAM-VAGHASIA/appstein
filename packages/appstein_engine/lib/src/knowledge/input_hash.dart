import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The SHA-256 of [bytes], as lowercase hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The hash of everything a generated `.appstein/` file is built from
/// (spec §6.2).
///
/// [inputs] maps a stable name for each input, such as
/// `sdk:packages/flutter_tools/lib/src/android/gradle_utils.dart`, to its
/// bytes, or to null when it is missing. Names are hashed instead of paths,
/// so a project moved to another folder keeps its hashes. The Appstein and
/// format versions are part of the hash, so a new Appstein regenerates its
/// files.
String inputHash(
  Map<String, List<int>?> inputs, {
  required String appsteinVersion,
  required int formatVersion,
}) {
  final names = inputs.keys.toList()..sort();
  final lines = [
    'appstein $appsteinVersion',
    'format $formatVersion',
    for (final name in names)
      '$name ${switch (inputs[name]) {
        null => 'missing',
        final bytes => sha256Hex(bytes),
      }}',
  ];
  return sha256Hex(utf8.encode(lines.join('\n')));
}
