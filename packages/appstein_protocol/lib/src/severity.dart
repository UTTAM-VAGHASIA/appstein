/// How serious a finding is (spec §9.3).
enum Severity {
  /// Blocks "done".
  error,

  /// Reported, but never blocks.
  warning,

  /// Advisory only.
  info,
}
