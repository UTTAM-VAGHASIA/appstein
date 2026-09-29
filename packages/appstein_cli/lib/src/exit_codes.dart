/// Exit codes shared by every command (spec §9.5).
abstract final class ExitCodes {
  /// No errors.
  static const ok = 0;

  /// Errors found. Used by the CLI and CI.
  static const errorsFound = 1;

  /// Appstein itself failed: bad usage, a bad environment or a crash.
  static const appsteinFailed = 3;
}
