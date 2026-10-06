import 'package:appstein_protocol/appstein_protocol.dart';

import '../map/map_sync.dart';
import 'knowledge_lock.dart';
import 'knowledge_sync.dart';
import 'knowledge_write_exception.dart';
import 'platform_sync.dart';

/// The problem a refresh reports when another process holds the knowledge
/// lock past the timeout.
const lockBusyProblem = 'another Appstein process holds the knowledge lock';

/// Whether the knowledge is up to date, and when it isn't, why. `appstein
/// docs` and `appstein verify` both start from one (spec §6.9, §9).
final class KnowledgeRefresh {
  /// The knowledge is up to date.
  const KnowledgeRefresh.current() : problem = null, fixHint = null;

  /// The knowledge could not be brought up to date.
  const KnowledgeRefresh.failed(String this.problem, {this.fixHint});

  /// The refresh the MCP server already ran before a tool call (spec §8):
  /// stale knowledge and a skipped project map both count as failed.
  factory KnowledgeRefresh.fromFreshness(FreshnessReport freshness) {
    if (freshness.problem case final problem?) {
      return KnowledgeRefresh.failed(problem, fixHint: freshness.fixHint);
    }
    if (freshness.mapSkipped case final skipped?) {
      return KnowledgeRefresh.failed(_mapMissing(skipped));
    }
    return const KnowledgeRefresh.current();
  }

  /// Why the knowledge is not up to date, in words that follow "because";
  /// null when it is.
  final String? problem;

  /// What to do about [problem], as a sentence; null when [problem] says
  /// enough.
  final String? fixHint;

  /// Whether the knowledge is up to date.
  bool get ok => problem == null;
}

String _mapMissing(String skipped) {
  final reason = skipped.endsWith('.')
      ? skipped.substring(0, skipped.length - 1)
      : skipped;
  return 'the project map is missing ($reason)';
}

/// Brings the knowledge of the project at [projectRoot] up to date with
/// [sync], as `appstein sync --detect` does.
///
/// It never throws for the project's own state: a sync that fails, a lock
/// that stays busy, a file that can't be written and a project map that was
/// skipped each give a failed result. [runAgain] ends the fix hints, such
/// as ``Then run `appstein docs` again.``; [dartSdkPath] is passed to the
/// sync, for tests.
Future<KnowledgeRefresh> refreshKnowledge(
  KnowledgeSync sync,
  String projectRoot, {
  String? dartSdkPath,
  required String runAgain,
}) async {
  final SyncReport report;
  try {
    report = await sync.detect(projectRoot, dartSdkPath: dartSdkPath);
  } on SyncException catch (error) {
    return KnowledgeRefresh.failed(error.problem, fixHint: error.fixHint);
  } on KnowledgeLockTimeout {
    return KnowledgeRefresh.failed(
      lockBusyProblem,
      fixHint: 'Wait for it to finish. $runAgain',
    );
  } on KnowledgeWriteException catch (error) {
    return KnowledgeRefresh.failed(
      'the knowledge could not be brought up to date ($error)',
      fixHint:
          'Check that the project folder is writable and that .appstein is '
          'a folder. $runAgain',
    );
  }
  if (report.map?.skipped case final skipped?) {
    return KnowledgeRefresh.failed(
      _mapMissing(skipped),
      fixHint: report.map!.packages == PackagesAction.fetchFailed
          ? 'Run `flutter pub get` in the project to see the whole error. '
                '$runAgain'
          : 'Fix that. $runAgain',
    );
  }
  return const KnowledgeRefresh.current();
}
