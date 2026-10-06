import 'package:appstein_protocol/appstein_protocol.dart';

import '../../docs/docs_folder.dart';
import '../../docs/docs_prepare.dart';
import '../verify_check.dart';

const _id = 'docs.stale';
const _render = 'Run `appstein docs`.';

String _sentence(String text) => text.endsWith('.') ? text : '$text.';

/// `docs.stale` (spec §9.2): the human docs match the knowledge and
/// weren't edited by hand (§6.9).
///
/// It renders every page as `appstein docs --check` does, with the same
/// code ([prepareDocs]), and reports one warning per page that differs,
/// saying why. It never writes a page, and reports nothing when
/// `docs.enabled` is false.
final class DocsStaleCheck implements VerifyCheck {
  /// Creates the check.
  const DocsStaleCheck();

  @override
  List<String> get ids => const [_id];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => true;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final config = context.config;
    if (!config.docs.enabled) return const [];
    final docsPath = config.docs.path;
    Finding finding(String file, String message, {String? fixHint}) => Finding(
      id: _id,
      severity: Severity.warning,
      file: file,
      message: message,
      fixHint: fixHint,
      knowledgeRef: '.appstein/INDEX.md',
    );

    switch (prepareDocs(
      projectRoot: context.projectRoot,
      config: config,
      packs: context.packs,
      snapshot: context.knowledge,
      decisions: context.decisions,
    )) {
      case DocsNotPrepared(:final problem, :final fixHint, :final details):
        return [
          finding(
            docsPath,
            'The pages could not be compared: '
            '${_sentence([problem, ...details].join(' '))}',
            fixHint: fixHint,
          ),
        ];
      case DocsPlan(:final changes, :final blocked):
        return [
          // Each sentence names the file and says what to do with it.
          for (final sentence in blocked) finding(docsPath, sentence),
          for (final change in changes)
            if (change.reason case final reason?)
              finding(
                '$docsPath/${change.path}',
                switch (reason) {
                  DocStaleReason.missing => 'The page is missing.',
                  DocStaleReason.behind => 'The page is behind the app.',
                  DocStaleReason.handEdited =>
                    'The page was edited by hand; `appstein docs` will '
                        'overwrite the edit.',
                  DocStaleReason.conflicted => 'The page has a merge conflict.',
                  DocStaleReason.notRendered =>
                    'The page is no longer rendered.',
                  DocStaleReason.editedLeftover =>
                    'The page is no longer rendered, and was edited by hand.',
                },
                fixHint: switch (reason) {
                  DocStaleReason.handEdited =>
                    'Run `appstein docs`, and keep your own text in a file '
                        'without the marker line.',
                  DocStaleReason.editedLeftover =>
                    'Delete it, or remove its first line to keep it as a '
                        'team note.',
                  _ => _render,
                },
              ),
        ];
    }
  }
}
