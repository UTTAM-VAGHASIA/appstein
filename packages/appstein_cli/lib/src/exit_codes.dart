/// Exit codes shared by every command (spec §9.5).
abstract final class ExitCodes {
  /// No errors.
  static const ok = 0;

  /// Errors found. Used by the CLI and CI.
  static const errorsFound = 1;

  /// Errors found in `--hook claude` mode: Claude Code shows stderr to the
  /// agent on this code.
  static const hookBlocked = 2;

  /// Appstein itself failed: bad usage, a bad environment or a crash.
  static const appsteinFailed = 3;
}
