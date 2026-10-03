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
}) => inputHashOfDigests(
  {
    for (final MapEntry(:key, :value) in inputs.entries)
      key: value == null ? null : sha256Hex(value),
  },
  appsteinVersion: appsteinVersion,
  formatVersion: formatVersion,
);

/// [inputHash] from each input's SHA-256 ([sha256Hex] of its bytes), or null
/// when it is missing, instead of its bytes. For the same inputs it gives
/// the same hash as [inputHash]. The map uses it: it keeps each file's
/// digest for `state.json` (spec §6.2).
String inputHashOfDigests(
  Map<String, String?> digests, {
  required String appsteinVersion,
  required int formatVersion,
}) {
  final names = digests.keys.toList()..sort();
  final lines = [
    'appstein $appsteinVersion',
    'format $formatVersion',
    for (final name in names) '$name ${digests[name] ?? 'missing'}',
  ];
  return sha256Hex(utf8.encode(lines.join('\n')));
}
