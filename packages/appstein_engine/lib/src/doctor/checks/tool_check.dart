import '../../host/executable_finder.dart';
import '../../host/host_environment.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks that a command-line tool is installed, and shows its version.
final class ToolCheck implements DoctorCheck {
  /// Creates a check for [command].
  const ToolCheck({
    required this.id,
    required this.title,
    required this.command,
    required this.why,
    required this.installHints,
  });

  @override
  final String id;

  @override
  final String title;

  /// The command, looked up on PATH.
  final String command;

  /// Why Appstein needs it. Shown when it is missing.
  final String why;

  /// How to install it on each OS.
  final Map<HostOs, String> installHints;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final path = findExecutable(command, context.environment);
    if (path == null) {
      return CheckResult.warning(
        '`$command` not found. $why',
        fixHint: installHints[context.environment.os],
      );
    }
    final result = await context.runner.run(path, ['--version']);
    return CheckResult.ok(
      result.ok ? firstLine(result.stdout) : '$command (version unknown)',
      details: ['Path: $path'],
    );
  }
}

/// git: `create` proposes the first commit and `upgrade` refuses a dirty tree.
const gitCheck = ToolCheck(
  id: 'doctor.git',
  title: 'git',
  command: 'git',
  why: 'Appstein uses it to propose commits and to protect upgrades.',
  installHints: {
    HostOs.windows: 'winget install Git.Git',
    HostOs.macos: 'xcode-select --install',
    HostOs.linux:
        'Install git with your package manager, e.g. `sudo apt install git`.',
  },
);

/// ripgrep: the Dart MCP server's package search needs it.
const ripgrepCheck = ToolCheck(
  id: 'doctor.ripgrep',
  title: 'ripgrep',
  command: 'rg',
  why: 'The Dart MCP server uses it to search package sources.',
  installHints: {
    HostOs.windows: 'winget install BurntSushi.ripgrep.MSVC',
    HostOs.macos: 'brew install ripgrep',
    HostOs.linux:
        'Install ripgrep with your package manager, e.g. '
        '`sudo apt install ripgrep`.',
  },
);
