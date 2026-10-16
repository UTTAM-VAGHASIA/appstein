import 'package:appstein_cli/src/failure.dart';
import 'package:appstein_cli/src/verify_hook.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  final trace = StackTrace.fromString('#0 here\n#1 there\n');

  String told(Object error) => describeFailure(error, trace).text;

  group('describeFailure, as the terminal tells it', () {
    // These words were written by `runAppstein` before the hook shared them.
    test('an analysis server that can\'t answer, and tests that can\'t be '
        'run: the reason and `appstein doctor`, no trace', () {
      expect(
        told(const CodeAnalysisException('it ended')),
        'The Dart analysis server could not answer: it ended.\n'
        'Run `appstein doctor` to check your setup.\n',
      );
      expect(
        told(const TestRunException('no Flutter SDK')),
        'The project\'s tests could not be run: no Flutter SDK.\n'
        'Run `appstein doctor` to check your setup.\n',
      );
    });

    test('a crash: the reason, what to do, and the trace', () {
      expect(
        told(StateError('boom')),
        'Appstein failed unexpectedly: Bad state: boom\n'
        'Run `appstein doctor` to check your setup. If this keeps happening, '
        'please report it with the details below.\n'
        '#0 here\n#1 there\n\n',
      );
    });

    test('a check that threw: the check\'s own trace', () {
      final own = StackTrace.fromString('#0 in the check\n');
      final text = describeFailure(
        VerifyCheckError('boom.check', StateError('x'), own),
        trace,
      ).text;
      expect(text, contains('The check `boom.check` failed'));
      expect(text, endsWith('#0 in the check\n\n'));
      expect(text, isNot(contains('#0 here')));
    });

    test('a run that can\'t start: the problem and the advice', () {
      expect(
        told(const CannotStart('There is no project.', 'Pass --project.')),
        'There is no project.\nPass --project.\n',
      );
    });

    test('an invalid appstein.yaml in any other command', () {
      expect(
        told(ConfigException('bad', sourcePath: 'appstein.yaml')),
        startsWith('Invalid appstein.yaml: '),
      );
    });
  });

  test('the hook tells the same reason as the terminal', () {
    for (final error in <Object>[
      const CodeAnalysisException('it ended'),
      const TestRunException('no Flutter SDK'),
      StateError('boom'),
      const CannotStart('There is no project.', 'Pass --project.'),
    ]) {
      final failure = describeFailure(error, trace);
      final reply = claudeFailureReply(failure.reason, details: failure.text);
      expect(reply.stderr, failure.text);
      expect(reply.stdout, contains(failure.reason.split('\n').first));
    }
  });
}
