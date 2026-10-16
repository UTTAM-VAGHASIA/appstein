// Run by verify_hook_test.dart as a separate process: `appstein verify --fast
// --hook claude` on a project the test made, through runGuarded as the real
// binary runs it, with an error that escapes every future raised while the
// run is going on or just after it has answered.
//
// Arguments: the project, the fake Flutter SDK, the analysis cache folder, and
// the order: `crash-then-answer` (the error fires while the check is still
// running, so the failure handler speaks first), `answer-then-crash` (the
// run answers with an error, and the error fires after it) or
// `answer-then-unsayable-crash` (as the last, with an error that can't even
// be turned into text).
import 'dart:async';
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import 'scripted_code_analysis.dart';

/// An error whose text can't be had: describing it throws.
final class _Unsayable {
  @override
  String toString() => throw StateError('no words');
}

/// A fast check that finds one error.
final class _OneError implements VerifyCheck {
  const _OneError({required this.crashFirst});

  /// Whether the error that escapes fires while this check runs.
  final bool crashFirst;

  @override
  List<String> get ids => const ['x.err'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    if (crashFirst) {
      Timer(Duration.zero, () => throw StateError('late crash'));
      // Long enough for the handler to answer first.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return const [
      Finding(
        id: 'x.err',
        severity: Severity.error,
        file: 'lib/a.dart',
        line: 1,
        message: 'Broken.',
      ),
    ];
  }
}

Future<void> main(List<String> args) {
  final [project, sdk, cache, order] = args;
  final crashFirst = order == 'crash-then-answer';
  const arguments = ['verify', '--fast', '--hook', 'claude'];
  return runGuarded(
    () => runAppstein(
      arguments,
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': sdk, analysisCacheVariable: cache},
        workingDirectory: project,
      ),
      dartSdkPath: p.dirname(p.dirname(Platform.resolvedExecutable)),
      hookInput: () async => '',
      verifyChecks: (_) => [
        (check: _OneError(crashFirst: crashFirst), pack: null),
      ],
      codeAnalysis: <T>(body) async {
        final result = await ScriptedCodeAnalysis().scope(body);
        // The run answers (microtasks only) well before this fires.
        if (!crashFirst) {
          final unsayable = order == 'answer-then-unsayable-crash';
          Timer(
            const Duration(milliseconds: 500),
            () => throw unsayable ? _Unsayable() : StateError('late crash'),
          );
        }
        return result;
      },
    ),
    arguments: arguments,
  );
}
