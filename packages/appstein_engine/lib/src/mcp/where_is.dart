import 'package:appstein_protocol/appstein_protocol.dart';

import '../text/edit_distance.dart';
import 'tool_answer.dart';

/// How many matches `where_is` lists (spec §8).
const whereIsLimit = 10;

/// The lowercase words of [text], split at camelCase humps and at every
/// character that isn't a letter or a digit: `LoginScreen`, `login_screen`
/// and `login_screen.dart` all give `login`, `screen`.
List<String> searchWords(String text) {
  final spaced = text
      .replaceAllMapped(
        RegExp('([a-z0-9])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAllMapped(
        RegExp('([A-Z]+)([A-Z][a-z])'),
        (match) => '${match[1]} ${match[2]}',
      );
  return [
    for (final word in spaced.toLowerCase().split(RegExp('[^a-z0-9]+')))
      if (word.isNotEmpty) word,
  ];
}

/// `where_is` (spec §8): the files and symbols of the project map that
/// match the free text [query], best first, deterministically.
///
/// The query is split into words ([searchWords]) and matched against four
/// kinds of candidate, each worth its tier for a word that matches:
/// - a symbol (5): a word of its name, or its whole name;
/// - a route (4): a word of its path or of its screen's name;
/// - a feature (3): a word of its name;
/// - a file (2): a word of its path.
///
/// A word of four or more letters that matches no word of a candidate
/// exactly scores 1 when it is at most two edits from one (a typo). A
/// candidate's score is the sum of each word's best score; ties go to the
/// name, then the file. It lists the top [whereIsLimit], each with the
/// reason for each word that matched.
ToolAnswer whereIs(
  String query, {
  required SymbolsMap symbols,
  required RoutesMap routes,
  required FeaturesMap features,
  required LayersMap layers,
}) {
  final words = searchWords(query);
  if (words.isEmpty) {
    return ToolRefusal('The query "$query" has no letters or digits to match.');
  }
  final candidates = [
    for (final symbol in symbols.symbols)
      _Candidate(
        kind: 'symbol',
        name: symbol.name,
        tier: 5,
        groups: [
          (
            {...searchWords(symbol.name), symbol.name.toLowerCase()},
            'the symbol name `${symbol.name}`',
          ),
        ],
        file: symbol.file,
        line: symbol.line,
        layer: symbol.layer,
        feature: symbol.feature,
        summary: symbol.summary,
      ),
    for (final route in routes.routes)
      if (route.path case final path?)
        _Candidate(
          kind: 'route',
          name: path,
          tier: 4,
          groups: [
            (searchWords(path).toSet(), 'the route path `$path`'),
            if (route.screen case final screen?)
              (searchWords(screen.name).toSet(), 'its screen `${screen.name}`'),
          ],
          file: route.file,
          line: route.line,
          feature: switch (route.screen) {
            final screen? => features.featureOf(screen.file),
            null => null,
          },
        ),
    for (final MapEntry(key: name, value: feature) in features.features.entries)
      _Candidate(
        kind: 'feature',
        name: name,
        tier: 3,
        groups: [(searchWords(name).toSet(), 'the feature name `$name`')],
        file: feature.folder,
      ),
    for (final MapEntry(key: path, value: entry) in layers.files.entries)
      _Candidate(
        kind: 'file',
        name: path,
        tier: 2,
        groups: [(searchWords(path).toSet(), 'the path `$path`')],
        file: path,
        layer: entry.layer,
        feature: entry.feature,
      ),
  ];
  final scored = [for (final candidate in candidates) ?candidate.score(words)]
    ..sort(_compare);
  final listed = scored.take(whereIsLimit).toList();
  return ToolReply(
    {
      'query': query,
      'total': scored.length,
      'matches': [for (final match in listed) match.toJson()],
    },
    switch (listed) {
      [] => 'Nothing in the project map matches "$query".',
      [final best, ...] =>
        'Best match for "$query": ${best.candidate.kind} '
            '`${best.candidate.name}`'
            '${best.candidate.file == null ? '' : ' in ${best.candidate.file}${best.candidate.line == null ? '' : ':${best.candidate.line}'}'}'
            '; ${scored.length} '
            '${scored.length == 1 ? 'candidate' : 'candidates'} matched.',
    },
  );
}

int _compare(_Match a, _Match b) {
  if (a.score != b.score) return b.score.compareTo(a.score);
  final byName = a.candidate.name.compareTo(b.candidate.name);
  if (byName != 0) return byName;
  return (a.candidate.file ?? '').compareTo(b.candidate.file ?? '');
}

/// Something `where_is` can find, with the word groups it is matched on;
/// every group scores [tier].
final class _Candidate {
  _Candidate({
    required this.kind,
    required this.name,
    required this.tier,
    required this.groups,
    this.file,
    this.line,
    this.layer,
    this.feature,
    this.summary,
  });

  final String kind;
  final String name;
  final int tier;
  final List<(Set<String>, String)> groups;
  final String? file;
  final int? line;
  final String? layer;
  final String? feature;
  final String? summary;

  /// How this candidate matches [words], or null when no word matches.
  _Match? score(List<String> words) {
    var total = 0;
    final reasons = <String>[];
    for (final word in words) {
      final exact = groups
          .where((group) => group.$1.contains(word))
          .firstOrNull;
      if (exact != null) {
        total += tier;
        reasons.add('`$word` is a word of ${exact.$2}');
        continue;
      }
      if (word.length < 4) continue;
      found:
      for (final (groupWords, what) in groups) {
        for (final candidateWord in groupWords) {
          if (editDistance(word, candidateWord) <= 2) {
            total += 1;
            reasons.add('`$word` is close to `$candidateWord` in $what');
            break found;
          }
        }
      }
    }
    return total == 0 ? null : _Match(this, total, reasons);
  }
}

final class _Match {
  _Match(this.candidate, this.score, this.reasons);

  final _Candidate candidate;
  final int score;
  final List<String> reasons;

  Map<String, Object?> toJson() => {
    'kind': candidate.kind,
    'name': candidate.name,
    'score': score,
    'reasons': reasons,
    'file': candidate.file,
    'line': candidate.line,
    'layer': candidate.layer,
    'feature': candidate.feature,
    'summary': candidate.summary,
  };
}
