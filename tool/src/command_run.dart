/// One run of an `appstein` command by a measuring tool: its exit code, what
/// it wrote and how long it took. Every terminal `verify` run and every hook
/// run is one; what "how long" ends at is up to the caller (a hook's ends
/// when its output has closed, `runHook`).
typedef CommandRun = ({
  int exitCode,
  String stdout,
  String stderr,
  Duration elapsed,
});

/// What a failed row says about [error]: the message of a [StateError] (the
/// tools' own way to say why), else the error as it prints (a
/// `ProcessException` or a `FileSystemException` has the reason in it).
String reasonOf(Object error) => error is StateError ? error.message : '$error';
