import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

/// [json] as it reads after crossing the connection.
Map<String, Object?> crossed(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

// The lines of the analysis host's connection that are told apart by a
// flag: the stop a client sends, and the turn and the ending a host sends.
void main() {
  test('the stop line is {"stop": true}, and only it reads as a stop', () {
    final stop = crossed(const AnalysisHostStop().toJson());
    expect(stop, {'stop': true});
    expect(AnalysisHostStop.isStop(stop), isTrue);
    expect(AnalysisHostStop.isStop({'stop': false}), isFalse);
    expect(AnalysisHostStop.isStop({'stop': 'true'}), isFalse);
    expect(
      AnalysisHostStop.isStop(
        crossed(
          const AnalysisHostQuestion(
            id: 0,
            kind: AnalysisHostQuestionKind.read,
          ).toJson(),
        ),
      ),
      isFalse,
    );
  });

  test('the ending line names its question, and is neither a turn nor an '
      'answer', () {
    final ending = crossed(const AnalysisHostEnding(3).toJson());
    expect(ending, {'id': 3, 'ending': true});
    expect(AnalysisHostEnding.isEnding(ending), isTrue);
    expect(AnalysisHostTurn.isTurn(ending), isFalse);
    expect(
      AnalysisHostEnding.isEnding(crossed(const AnalysisHostTurn(3).toJson())),
      isFalse,
    );
    expect(
      AnalysisHostEnding.isEnding(
        crossed(const AnalysisHostAnswer.failed(3, 'why').toJson()),
      ),
      isFalse,
    );
  });
}
