import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../knowledge/support/sync_harness.dart';
import '../../support/fake_process_runner.dart';
import '../../support/fixture_app.dart';

/// A check for tests: it reports [findings], or throws [error].
final class FakeCheck implements VerifyCheck {
  /// Creates the check.
  FakeCheck(
    this.ids, {
    this.mode = VerifyMode.full,
    this.needsMap = false,
    this.findings = const [],
    this.error,
  });

  @override
  final List<String> ids;

  @override
  final VerifyMode mode;

  @override
  final bool needsMap;

  /// What it reports.
  final List<Finding> findings;

  /// What it throws instead, when set.
  final Object? error;

  /// How often it ran.
  int runs = 0;

  /// The context of its last run.
  VerifyContext? seen;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    runs++;
    seen = context;
    if (error case final error?) throw error;
    return findings;
  }
}

/// A finding with test defaults.
Finding finding(
  String id, {
  Severity severity = Severity.warning,
  String? file,
  int? line,
  String message = 'm',
  String? pack,
}) => Finding(
  id: id,
  severity: severity,
  file: file,
  line: line,
  message: message,
  pack: pack,
);

/// Syncs the project at [app] on the fake Flutter SDK at [flutterRoot], then
/// gives what a check reads: one reading of its knowledge.
Future<VerifyContext> contextFor(
  String app, {
  required String flutterRoot,
  List<Pack> packs = const [],
  AppsteinConfig config = const AppsteinConfig(),
}) async {
  await knowledgeSync(
    flutterRoot: flutterRoot,
    runner: FakeProcessRunner(),
    packs: packs,
    packageSkills: false,
  ).detect(app, dartSdkPath: testDartSdk);
  return VerifyContext(
    projectRoot: app,
    config: config,
    packs: packs,
    knowledge: KnowledgeSnapshot(app),
    decisions: readDecisions(app),
  );
}
