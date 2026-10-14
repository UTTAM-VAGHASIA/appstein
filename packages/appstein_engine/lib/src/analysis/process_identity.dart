import 'dart:ffi';
import 'dart:io';

/// What tells a running process from every other: its ID alone does not,
/// since an operating system gives the ID of an ended process to a new one
/// (Windows often within seconds). Two identities are the same process only
/// when the ID, the start and the image all agree.
final class ProcessIdentity {
  /// Creates an identity.
  const ProcessIdentity({
    required this.id,
    required this.start,
    required this.image,
  });

  /// The process ID.
  final int id;

  /// When it started, as the operating system tells it: text that is the
  /// same every time it is asked for one process.
  final String start;

  /// The program it runs: the full path of its executable on Windows, the
  /// command's name elsewhere.
  final String image;

  @override
  bool operator ==(Object other) =>
      other is ProcessIdentity &&
      other.id == id &&
      other.start == start &&
      other.image == image;

  @override
  int get hashCode => Object.hash(id, start, image);

  @override
  String toString() => 'process $id ($image, started $start)';
}

/// What the operating system says runs under a process ID now.
sealed class ProcessSeen {
  const ProcessSeen();
}

/// A process runs under the ID, and this is who it is.
final class ProcessRunning extends ProcessSeen {
  /// Creates the answer.
  const ProcessRunning(this.identity);

  /// The process that runs under the ID.
  final ProcessIdentity identity;
}

/// No process runs under the ID that Appstein could have started: none
/// does, it has ended, or it is another user's.
final class ProcessGone extends ProcessSeen {
  /// Creates the answer.
  const ProcessGone();
}

/// Something may run under the ID, but who it is can't be told: the
/// question failed, or the system's tools don't give a start (BusyBox's
/// `ps` has no `lstart`). Whoever asks treats it as "not shown to be
/// mine", and does not take it for "gone" either.
final class ProcessUnknown extends ProcessSeen {
  /// Creates the answer.
  const ProcessUnknown();
}

/// Asks the operating system which process runs under an ID now.
typedef ProcessLookup = ProcessSeen Function(int id);

/// The [ProcessLookup] of this system. It adds no package and starts no
/// PowerShell: on Windows it asks `kernel32` directly (microseconds), and
/// elsewhere it runs `ps` (milliseconds). It never throws: a failure is
/// [ProcessUnknown].
ProcessSeen lookUpProcess(int id) {
  try {
    return Platform.isWindows ? _windowsProcess(id) : _psProcess(id);
  } on Object {
    return const ProcessUnknown();
  }
}

/// The command a person can run to end the process with the ID [id] by
/// hand. On Windows it ends it only while it still runs the program
/// [image] (the file name is enough), when that is known. The Windows form
/// uses `-` for its switches, so it works as it is in cmd, PowerShell and
/// Git Bash (Git Bash would turn a `/PID` into a path).
String endByHandCommand(int id, {String? image}) {
  if (!Platform.isWindows) return 'kill $id';
  if (image == null) return 'taskkill -PID $id -F';
  final name = image.split(RegExp(r'[\\/]')).last;
  return 'taskkill -PID $id -FI "IMAGENAME eq $name" -F';
}

/// `ps -o lstart=,comm= -p <id>`: the start is five words (`Wed Oct 14
/// 04:00:00 2026`), the command is the rest. When `ps` can't answer that,
/// Linux's `/proc` still says whether the process exists.
ProcessSeen _psProcess(int id) {
  final asked = Process.runSync('ps', ['-o', 'lstart=,comm=', '-p', '$id']);
  final words = '${asked.stdout}'.trim().split(RegExp(r'\s+'));
  if (asked.exitCode != 0 || words.length < 6) {
    if (asked.exitCode == 1 && '${asked.stdout}'.trim().isEmpty) {
      // `ps -p` found no such process, which it says with exit code 1 and
      // nothing on stdout.
      final proc = Directory('/proc');
      if (!proc.existsSync()) return const ProcessGone();
      return Directory('/proc/$id').existsSync()
          ? const ProcessUnknown()
          : const ProcessGone();
    }
    return const ProcessUnknown();
  }
  return ProcessRunning(
    ProcessIdentity(
      id: id,
      start: words.take(5).join(' '),
      image: words.skip(5).join(' '),
    ),
  );
}

// Windows. The library is opened only here, so the code loads on systems
// that have no `kernel32`.
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _openProcess = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32 access, Int32 inherit, Uint32 id),
      int Function(int access, int inherit, int id)
    >('OpenProcess');
final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr handle), int Function(int handle)>(
      'CloseHandle',
    );
final _getExitCodeProcess = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr handle, Pointer<Uint32> code),
      int Function(int handle, Pointer<Uint32> code)
    >('GetExitCodeProcess');
final _getProcessTimes = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr handle,
        Pointer<Uint64> created,
        Pointer<Uint64> exited,
        Pointer<Uint64> kernel,
        Pointer<Uint64> user,
      ),
      int Function(
        int handle,
        Pointer<Uint64> created,
        Pointer<Uint64> exited,
        Pointer<Uint64> kernel,
        Pointer<Uint64> user,
      )
    >('GetProcessTimes');
final _queryFullProcessImageName = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr handle,
        Uint32 flags,
        Pointer<Uint16> name,
        Pointer<Uint32> length,
      ),
      int Function(
        int handle,
        int flags,
        Pointer<Uint16> name,
        Pointer<Uint32> length,
      )
    >('QueryFullProcessImageNameW');
final _localAlloc = _kernel32
    .lookupFunction<
      Pointer<Uint8> Function(Uint32 flags, IntPtr bytes),
      Pointer<Uint8> Function(int flags, int bytes)
    >('LocalAlloc');
final _localFree = _kernel32
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Uint8> memory),
      Pointer<Uint8> Function(Pointer<Uint8> memory)
    >('LocalFree');

/// The least access that answers these questions; it is granted for a
/// process of the same user, which every process Appstein starts is.
const _queryLimitedInformation = 0x1000;

/// What `GetExitCodeProcess` gives for a process that has not ended.
const _stillActive = 259;

/// `LPTR`: fixed memory, filled with zeros.
const _zeroed = 0x0040;

/// The most characters of an image path that are read.
const _pathLength = 2048;

ProcessSeen _windowsProcess(int id) {
  final handle = _openProcess(_queryLimitedInformation, 0, id);
  // No such process, or not this user's: every process Appstein starts can
  // be opened with this right.
  if (handle == 0) return const ProcessGone();
  // Four times of 8 bytes, the exit code and the path's length of 4 bytes
  // each, then the path.
  const timesAt = 0;
  const codeAt = 32;
  const lengthAt = 36;
  const pathAt = 40;
  var memory = Pointer<Uint8>.fromAddress(0);
  try {
    memory = _localAlloc(_zeroed, pathAt + _pathLength * 2);
    if (memory.address == 0) return const ProcessUnknown();
    // An ended process whose handle someone still holds can be opened, and
    // has a start: it is running only when it has no exit code yet.
    final code = Pointer<Uint32>.fromAddress(memory.address + codeAt);
    if (_getExitCodeProcess(handle, code) == 0) return const ProcessUnknown();
    if (code.value != _stillActive) return const ProcessGone();
    final times = Pointer<Uint64>.fromAddress(memory.address + timesAt);
    if (_getProcessTimes(handle, times, times + 1, times + 2, times + 3) == 0) {
      return const ProcessUnknown();
    }
    final length = Pointer<Uint32>.fromAddress(memory.address + lengthAt)
      ..value = _pathLength;
    final path = Pointer<Uint16>.fromAddress(memory.address + pathAt);
    // It fails for a process that has just ended, which then has no image.
    if (_queryFullProcessImageName(handle, 0, path, length) == 0) {
      return const ProcessUnknown();
    }
    return ProcessRunning(
      ProcessIdentity(
        id: id,
        start: '${times.value}',
        image: String.fromCharCodes(path.asTypedList(length.value)),
      ),
    );
  } finally {
    if (memory.address != 0) _localFree(memory);
    _closeHandle(handle);
  }
}
