import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  group('docSummary', () {
    test('takes the first sentence of the first paragraph', () {
      expect(
        docSummary(
          '/// A trip the user has booked. It holds where they go,\n'
          '/// and more.\n///\n/// Second paragraph.',
        ),
        'A trip the user has booked.',
      );
    });

    test('joins a sentence that spans lines', () {
      expect(
        docSummary('/// Loads the bookings\n/// for the home screen. More.'),
        'Loads the bookings for the home screen.',
      );
    });

    test('ends a sentence at ! and ?', () {
      expect(
        docSummary('/// Describes [status] for the user! Then more.'),
        'Describes [status] for the user!',
      );
      expect(docSummary('/// Is it ready? Yes.'), 'Is it ready?');
    });

    test('keeps a paragraph without a full stop whole', () {
      expect(docSummary('/// The signed-in user'), 'The signed-in user');
    });

    test('a full stop inside a word ends nothing', () {
      expect(
        docSummary('/// Uses v1.2 of the API. More.'),
        'Uses v1.2 of the API.',
      );
    });

    test('reads block comments', () {
      expect(docSummary('/**\n * Block style. Rest.\n */'), 'Block style.');
    });

    test('reads CRLF comments', () {
      expect(docSummary('/// One.\r\n/// Two.'), 'One.');
    });

    test('a missing or empty comment has no summary', () {
      expect(docSummary(null), isNull);
      expect(docSummary('///\n///'), isNull);
    });
  });

  test('symbols: the public top-level declarations in lib/, sorted, with '
      'layer, feature and summary', () async {
    final app = copyFixtureApp();
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final symbols = buildSymbols(
      analysis,
      layerOf: (file) => file.startsWith('lib/utils/') ? 'utils' : null,
      featureOf: (file) => file.startsWith('lib/ui/home/') ? 'home' : null,
    ).symbols;

    const utils = 'lib/utils/result.dart';
    expect(
      [
        for (final s in symbols)
          if (s.file == utils) (s.name, s.kind),
      ],
      [
        ('Result', SymbolKind.classKind),
        ('Ok', SymbolKind.classKind),
        ('Failure', SymbolKind.classKind),
        ('Loggable', SymbolKind.mixinKind),
        ('BookingStatus', SymbolKind.enumKind),
        ('StatusWords', SymbolKind.extension),
        ('BookingId', SymbolKind.extensionType),
        ('Json', SymbolKind.typedef),
        ('describe', SymbolKind.function),
        ('useHidden', SymbolKind.function),
      ],
    );

    final describe = symbols.singleWhere((s) => s.name == 'describe');
    expect(describe.toJson(), {
      'name': 'describe',
      'kind': 'function',
      'file': utils,
      'line': lineOf(app, utils, 'String describe('),
      'layer': 'utils',
      'feature': null,
      'summary': 'Describes [status] for the user!',
    });

    final home = symbols.singleWhere((s) => s.name == 'HomeViewModel');
    expect(home.feature, 'home');
    expect(home.layer, isNull);
    expect(home.summary, "Loads the user's bookings for the home screen.");

    expect(
      symbols.singleWhere((s) => s.name == 'Booking').summary,
      'A trip the user has booked.',
    );
    expect(
      symbols.singleWhere((s) => s.name == 'User').summary,
      'The signed-in user',
    );
    expect(
      symbols.singleWhere((s) => s.name == 'main').kind,
      SymbolKind.function,
    );

    final names = symbols.map((s) => s.name);
    // A getter, a private class and an unnamed extension aren't symbols.
    expect(names, isNot(contains('appName')));
    expect(names, isNot(contains('_Hidden')));
    expect(symbols.where((s) => !s.file.startsWith('lib/')), isEmpty);
    // _NoAnalytics is private; FakeBookingRepository is in testing/.
    expect(names, isNot(contains('FakeBookingRepository')));

    final sorted = [...symbols]
      ..sort((a, b) {
        final byFile = a.file.compareTo(b.file);
        if (byFile != 0) return byFile;
        final byLine = a.line.compareTo(b.line);
        return byLine != 0 ? byLine : a.name.compareTo(b.name);
      });
    expect(symbols, orderedEquals(sorted));
  });
}
