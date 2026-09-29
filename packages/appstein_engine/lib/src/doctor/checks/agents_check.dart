import '../../host/executable_finder.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks which supported agent CLIs are installed. It only runs
/// `--version`; Appstein never touches agent logins (spec §4, principle 6).
final class AgentsCheck implements DoctorCheck {
  /// Creates the check.
  const AgentsCheck();

  static const _agents = [('claude', 'Claude Code'), ('codex', 'Codex')];

  @override
  String get id => 'doctor.agents';

  @override
  String get title => 'Agent CLIs';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final found = <String>[];
    final details = <String>[];
    for (final (command, name) in _agents) {
      final path = findExecutable(command, context.environment);
      if (path == null) {
        details.add('$name: not installed');
        continue;
      }
      final result = await context.runner.run(path, [
        '--version',
      ], timeout: const Duration(seconds: 10));
      found.add(name);
      details.add(
        '$name: ${result.ok ? firstLine(result.stdout) : 'version '
                  'unknown'} ($path)',
      );
    }
    if (found.isEmpty) {
      return CheckResult.warning(
        'No supported agent CLI found (Claude Code or Codex).',
        details: details,
        fixHint:
            'Install Claude Code or Codex and log in through its own '
            'command. Appstein never handles your login.',
      );
    }
    return CheckResult.ok('${found.join(' and ')} found', details: details);
  }
}
