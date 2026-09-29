import 'dart:math' show min;

/// The Levenshtein distance between [a] and [b]: the fewest single-character
/// insertions, deletions or substitutions that turn one into the other.
int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = min(
        min(previous[j] + 1, current[j - 1] + 1),
        previous[j - 1] + cost,
      );
    }
    previous = current;
  }
  return previous[b.length];
}

/// The candidate closest to [input], if it is at most [maxDistance] edits
/// away. Ties go to the earlier candidate. Used for "did you mean" hints.
String? closestMatch(
  String input,
  Iterable<String> candidates, {
  int maxDistance = 2,
}) {
  String? best;
  var bestDistance = maxDistance + 1;
  for (final candidate in candidates) {
    final distance = editDistance(input, candidate);
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}
