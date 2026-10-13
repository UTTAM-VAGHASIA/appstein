import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify_check.dart';

/// The ID of the finding for an analyzer plugin that failed. It is
/// provisional until the owner confirms it, and written nowhere else.
const pluginFailedId = 'dart.plugin_failed';

/// `dart.plugin_failed`: an analyzer plugin named in `analysis_options.yaml`
/// could not be loaded or run (slice 1d.2). The analysis server says so and
/// then reports its analysis done as usual, without that plugin's rules.
/// Without this finding, a project whose lint plugin is broken would read
/// as a project with no lint problems.
///
/// One error per message of the server, about the project as a whole, in a
/// fast run too. `dart analyze` prints the same message and fails.
final class PluginFailedCheck implements GatheringCheck {
  /// Creates the check.
  const PluginFailedCheck();

  @override
  List<String> get ids => const [pluginFailedId];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) => gathering.code();

  @override
  Future<List<Finding>> run(VerifyContext context) async => [
    for (final failure in context.code.pluginFailures)
      Finding(
        id: pluginFailedId,
        severity: Severity.error,
        message:
            'An analyzer plugin failed, so its rules were not checked: '
            '${failure.endsWith('.') ? failure : '$failure.'}',
        fixHint:
            'Check the plugin\'s entry under `plugins:` in '
            '`analysis_options.yaml`, and run `appstein doctor`.',
      ),
  ];
}
