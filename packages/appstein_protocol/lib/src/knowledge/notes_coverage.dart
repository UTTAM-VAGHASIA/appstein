/// How well Appstein's curated notes cover a Flutter SDK (spec §6.4).
enum NotesCoverage {
  /// There are notes up to this SDK's minor version.
  complete,

  /// The SDK is newer than the newest notes, so notes may be incomplete.
  /// Everything generated from the SDK itself still works.
  partial,
}
