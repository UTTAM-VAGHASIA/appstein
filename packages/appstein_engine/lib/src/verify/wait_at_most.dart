import 'dart:async';

/// Waits for [work] at most [limit]: its result when it comes first, else
/// what [onLimit] returns or throws. An error [work] raises before then is
/// raised here; one it raises after is dropped, since nobody waits for it and
/// an error nobody listens to would reach the process as an uncaught one.
/// [work] itself is not stopped.
Future<T> waitAtMost<T>(
  Future<T> work,
  Duration limit, {
  required T Function() onLimit,
}) {
  final done = Completer<T>();
  final timer = Timer(limit.isNegative ? Duration.zero : limit, () {
    if (done.isCompleted) return;
    try {
      done.complete(onLimit());
    } on Object catch (error, stackTrace) {
      done.completeError(error, stackTrace);
    }
  });
  work.then<void>(
    (value) {
      timer.cancel();
      if (!done.isCompleted) done.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      timer.cancel();
      if (!done.isCompleted) done.completeError(error, stackTrace);
    },
  );
  return done.future;
}
