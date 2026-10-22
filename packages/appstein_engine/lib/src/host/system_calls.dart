import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_kernel32.dart';

/// A folder the system names for the user, or, when it names none, why
/// (`problem`).
typedef SystemFolder = ({String? folder, String? problem});

/// What a [SystemFolder] says when the system names no Local AppData folder.
const noLocalAppData = 'the system did not name the Local AppData folder';

/// What a [SystemFolder] says when the system names no temporary folder of
/// the user's.
const noUserTemp = "the system did not name the user's temporary folder";

/// The answers of the operating system that the analysis host's folder is
/// chosen from, asked by `dart:ffi` (no process is started, and no package is
/// added); tests give their own.
///
/// Each method answers on its own system and gives null (or no folder) on
/// the others, where it is not used:
/// - [effectiveUserId] and [homeOfUser] on macOS (`geteuid`, `getpwuid_r`:
///   macOS users are not in `/etc/passwd`, and there is no `getent`);
/// - [userTempFolder] on macOS (`confstr`);
/// - [localAppData], [userSid] and [windowsFolder] on Windows;
/// - [machineId] on macOS (`gethostuuid`) and Windows (the `MachineGuid` of
///   `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography`); Linux reads its
///   machine ID from a file (`MachineFacts`).
abstract interface class SystemCalls {
  /// The calls of the system this process runs on.
  static const SystemCalls real = _RealSystemCalls();

  /// The effective user ID (`geteuid`, macOS); null elsewhere.
  int? effectiveUserId();

  /// The home of the user [uid] as the user database has it (`getpwuid_r`,
  /// macOS); null when there is none, or elsewhere.
  String? homeOfUser(int uid);

  /// The user's temporary folder as the system names it (macOS:
  /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, used only when it is the sibling
  /// `T` of `confstr(_CS_DARWIN_USER_DIR)`), without a trailing `/`.
  SystemFolder userTempFolder();

  /// The Local AppData known folder of the user as the system names it for
  /// this process's own access token (Windows: `SHGetKnownFolderPath` with
  /// `FOLDERID_LocalAppData` and the token, so neither `%LOCALAPPDATA%` nor
  /// `%USERPROFILE%` changes it).
  SystemFolder localAppData();

  /// The SID of the user of this process's access token, as text
  /// (`S-1-5-21-…`; Windows); null when it can't be read, or elsewhere.
  String? userSid();

  /// The system's Windows folder (`GetSystemWindowsDirectoryW`, the shared
  /// one also on a terminal server); null when it can't be read, or
  /// elsewhere.
  String? windowsFolder();

  /// The machine's ID as 32 lower-case hex characters (macOS: the host UUID
  /// of `gethostuuid`; Windows: the `MachineGuid` without its dashes); null
  /// when it can't be read, or on Linux.
  String? machineId();
}

final class _RealSystemCalls implements SystemCalls {
  const _RealSystemCalls();

  @override
  int? effectiveUserId() => Platform.isMacOS ? _guard(() => _geteuid()) : null;

  @override
  String? homeOfUser(int uid) =>
      Platform.isMacOS ? _guard(() => _macHome(uid)) : null;

  @override
  SystemFolder userTempFolder() {
    if (!Platform.isMacOS) return (folder: null, problem: null);
    try {
      return userTempFolderFrom(
        userDir: _confstr(_csDarwinUserDir),
        temp: _confstr(_csDarwinUserTempDir),
        suffix: Platform.environment['DIRHELPER_USER_DIR_SUFFIX'],
      );
    } on Object catch (error) {
      return (folder: null, problem: '$noUserTemp ($error)');
    }
  }

  @override
  SystemFolder localAppData() {
    if (!Platform.isWindows) return (folder: null, problem: null);
    try {
      return _knownLocalAppData();
    } on Object catch (error) {
      return (folder: null, problem: '$noLocalAppData ($error)');
    }
  }

  @override
  String? userSid() => Platform.isWindows ? _guard(_tokenUserSid) : null;

  @override
  String? windowsFolder() =>
      Platform.isWindows ? _guard(_systemWindowsFolder) : null;

  @override
  String? machineId() => Platform.isWindows
      ? _guard(_machineGuid)
      : Platform.isMacOS
      ? _guard(_hostUuid)
      : null;
}

/// [read]'s answer, or null when it throws.
T? _guard<T>(T? Function() read) {
  try {
    return read();
  } on Object {
    return null;
  }
}

/// The user's temporary folder from the two answers of macOS's `confstr`
/// ([userDir], `_CS_DARWIN_USER_DIR`, `…/0/`; [temp],
/// `_CS_DARWIN_USER_TEMP_DIR`, `…/T/`) and the `DIRHELPER_USER_DIR_SUFFIX`
/// variable ([suffix]).
///
/// The system's helper builds both from the user's ID and UUID
/// (`/var/folders/<2>/<encoded>/`) and adds `<suffix>/` to them when the
/// variable is set; when the helper fails, `confstr` gives `$TMPDIR` (else
/// `P_tmpdir`) for the temporary folder but nothing for the user folder. So:
/// a trailing `/` is removed, and the suffix when both end in it (it is read
/// only to undo its effect, so every process of the user gets one folder);
/// the temporary folder is used only when it is the user folder's sibling
/// named `T`. Otherwise there is none, and `problem` says so.
SystemFolder userTempFolderFrom({
  required String? userDir,
  required String? temp,
  String? suffix,
}) {
  String? plain(String? path) {
    if (path == null || path.isEmpty) return null;
    var it = path;
    while (it.length > 1 && it.endsWith('/')) {
      it = it.substring(0, it.length - 1);
    }
    return it;
  }

  var dir = plain(userDir);
  var tmp = plain(temp);
  if (dir == null || tmp == null) return (folder: null, problem: noUserTemp);
  if (suffix != null && suffix.isNotEmpty) {
    final end = '/${plain(suffix)}';
    if (dir.endsWith(end) && tmp.endsWith(end)) {
      dir = dir.substring(0, dir.length - end.length);
      tmp = tmp.substring(0, tmp.length - end.length);
    }
  }
  if (!p.posix.isAbsolute(tmp) ||
      p.posix.dirname(tmp) != p.posix.dirname(dir) ||
      p.posix.basename(tmp) != 'T') {
    return (folder: null, problem: noUserTemp);
  }
  return (folder: tmp, problem: null);
}

// ---------------------------------------------------------------------------
// Memory, without `package:ffi`: `LocalAlloc` on Windows, `malloc` elsewhere.

Pointer<Uint8> _alloc(int bytes) {
  final memory = Platform.isWindows ? localAlloc(lptr, bytes) : _malloc(bytes);
  if (memory.address == 0) throw StateError('no memory');
  if (!Platform.isWindows) memory.asTypedList(bytes).fillRange(0, bytes, 0);
  return memory;
}

void _free(Pointer<NativeType> memory) {
  if (memory.address == 0) return;
  if (Platform.isWindows) {
    localFree(memory.cast());
  } else {
    _freeNative(memory.cast());
  }
}

/// Memory for one pointer (or a pointer-sized handle) that a call writes,
/// filled with zeros; the caller frees it with [_free].
Pointer<Pointer<T>> _pointerSlot<T extends NativeType>() =>
    _alloc(sizeOf<IntPtr>()).cast();

/// [text] as UTF-16 with a NUL, in memory the caller frees.
Pointer<Uint16> _utf16(String text) {
  final units = text.codeUnits;
  final memory = _alloc((units.length + 1) * 2).cast<Uint16>();
  final list = memory.asTypedList(units.length + 1);
  list.setRange(0, units.length, units);
  list[units.length] = 0;
  return memory;
}

/// The UTF-16 text at [text], up to its NUL.
String _readUtf16(Pointer<Uint16> text) {
  var length = 0;
  while ((text + length).value != 0) {
    length++;
  }
  return String.fromCharCodes(text.asTypedList(length));
}

/// The UTF-8 text at [text], up to its NUL.
String _readUtf8(Pointer<Uint8> text) {
  var length = 0;
  while ((text + length).value != 0) {
    length++;
  }
  return utf8.decode(text.asTypedList(length), allowMalformed: true);
}

/// Throws a [FileSystemException] for [path] off Windows: the calls below
/// exist only there.
void _windowsOnly(String path) {
  if (!Platform.isWindows) {
    throw FileSystemException(
      'an access list can be set on Windows only',
      path,
    );
  }
}

// ---------------------------------------------------------------------------
// Windows. The libraries are opened in lazy top-level finals, so this code
// loads on every system.

final _advapi32 = DynamicLibrary.open('advapi32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _ole32 = DynamicLibrary.open('ole32.dll');

final _getCurrentProcess = kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final _getSystemWindowsDirectory = kernel32
    .lookupFunction<
      Uint32 Function(Pointer<Uint16> buffer, Uint32 size),
      int Function(Pointer<Uint16> buffer, int size)
    >('GetSystemWindowsDirectoryW');
final _createDirectory = kernel32
    .lookupFunction<
      Int32 Function(Pointer<Uint16> path, Pointer<Uint8> attributes),
      int Function(Pointer<Uint16> path, Pointer<Uint8> attributes)
    >('CreateDirectoryW');
final _openProcessToken = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr process, Uint32 access, Pointer<IntPtr> token),
      int Function(int process, int access, Pointer<IntPtr> token)
    >('OpenProcessToken');
final _getTokenInformation = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr token,
        Int32 kind,
        Pointer<Uint8> info,
        Uint32 length,
        Pointer<Uint32> returned,
      ),
      int Function(
        int token,
        int kind,
        Pointer<Uint8> info,
        int length,
        Pointer<Uint32> returned,
      )
    >('GetTokenInformation');
final _convertSidToStringSid = _advapi32
    .lookupFunction<
      Int32 Function(Pointer<Uint8> sid, Pointer<Pointer<Uint16>> text),
      int Function(Pointer<Uint8> sid, Pointer<Pointer<Uint16>> text)
    >('ConvertSidToStringSidW');
final _getNamedSecurityInfo = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer<Uint16> name,
        Int32 type,
        Uint32 info,
        Pointer<Pointer<Uint8>> owner,
        Pointer<Pointer<Uint8>> group,
        Pointer<Pointer<Uint8>> dacl,
        Pointer<Pointer<Uint8>> sacl,
        Pointer<Pointer<Uint8>> descriptor,
      ),
      int Function(
        Pointer<Uint16> name,
        int type,
        int info,
        Pointer<Pointer<Uint8>> owner,
        Pointer<Pointer<Uint8>> group,
        Pointer<Pointer<Uint8>> dacl,
        Pointer<Pointer<Uint8>> sacl,
        Pointer<Pointer<Uint8>> descriptor,
      )
    >('GetNamedSecurityInfoW');
final _setNamedSecurityInfo = _advapi32
    .lookupFunction<
      Uint32 Function(
        Pointer<Uint16> name,
        Int32 type,
        Uint32 info,
        Pointer<Uint8> owner,
        Pointer<Uint8> group,
        Pointer<Uint8> dacl,
        Pointer<Uint8> sacl,
      ),
      int Function(
        Pointer<Uint16> name,
        int type,
        int info,
        Pointer<Uint8> owner,
        Pointer<Uint8> group,
        Pointer<Uint8> dacl,
        Pointer<Uint8> sacl,
      )
    >('SetNamedSecurityInfoW');
final _sddlToDescriptor = _advapi32
    .lookupFunction<
      Int32 Function(
        Pointer<Uint16> sddl,
        Uint32 revision,
        Pointer<Pointer<Uint8>> descriptor,
        Pointer<Uint32> size,
      ),
      int Function(
        Pointer<Uint16> sddl,
        int revision,
        Pointer<Pointer<Uint8>> descriptor,
        Pointer<Uint32> size,
      )
    >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
final _getSecurityDescriptorDacl = _advapi32
    .lookupFunction<
      Int32 Function(
        Pointer<Uint8> descriptor,
        Pointer<Int32> present,
        Pointer<Pointer<Uint8>> dacl,
        Pointer<Int32> defaulted,
      ),
      int Function(
        Pointer<Uint8> descriptor,
        Pointer<Int32> present,
        Pointer<Pointer<Uint8>> dacl,
        Pointer<Int32> defaulted,
      )
    >('GetSecurityDescriptorDacl');
final _regGetValue = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr key,
        Pointer<Uint16> subKey,
        Pointer<Uint16> value,
        Uint32 flags,
        Pointer<Uint32> type,
        Pointer<Uint8> data,
        Pointer<Uint32> bytes,
      ),
      int Function(
        int key,
        Pointer<Uint16> subKey,
        Pointer<Uint16> value,
        int flags,
        Pointer<Uint32> type,
        Pointer<Uint8> data,
        Pointer<Uint32> bytes,
      )
    >('RegGetValueW');
final _shGetKnownFolderPath = _shell32
    .lookupFunction<
      Int32 Function(
        Pointer<Uint8> folderId,
        Uint32 flags,
        IntPtr token,
        Pointer<Pointer<Uint16>> path,
      ),
      int Function(
        Pointer<Uint8> folderId,
        int flags,
        int token,
        Pointer<Pointer<Uint16>> path,
      )
    >('SHGetKnownFolderPath');
final _coTaskMemFree = _ole32
    .lookupFunction<
      Void Function(Pointer<Void> memory),
      void Function(Pointer<Void> memory)
    >('CoTaskMemFree');

/// `TOKEN_QUERY | TOKEN_IMPERSONATE | TOKEN_DUPLICATE`: what
/// `SHGetKnownFolderPath` needs of the token it is given.
const _tokenForKnownFolder = 0xE;

/// `TOKEN_QUERY`.
const _tokenQuery = 0x8;

/// `TokenUser`, the class of `GetTokenInformation` that gives the user's SID.
const _tokenUser = 1;

/// `FOLDERID_LocalAppData`, {F1B32785-6FBA-4FCF-9D55-7B8E7F157091}, as the 16
/// bytes of a `GUID` in memory (`Data1`, `Data2` and `Data3` little-endian).
const _folderIdLocalAppData = [
  0x85, 0x27, 0xB3, 0xF1, 0xBA, 0x6F, 0xCF, 0x4F, //
  0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91,
];

/// `HKEY_LOCAL_MACHINE`: `(HKEY)(ULONG_PTR)((LONG)0x80000002)` in `winreg.h`,
/// so the 32-bit value sign-extended to a pointer (`0xFFFFFFFF80000002` on a
/// 64-bit system).
const _hkeyLocalMachine = 0x80000002 - 0x100000000;

/// `RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY`: a string, from the 64-bit view of
/// the registry also in a 32-bit process.
const _regStringFrom64BitView = 0x2 | 0x10000;

/// Runs [use] with this process's own access token, opened with [access],
/// and closes it after. Throws when it can't be opened.
T _withOwnToken<T>(int access, T Function(int token) use) {
  final slot = _pointerSlot<NativeType>().cast<IntPtr>();
  var token = 0;
  try {
    if (_openProcessToken(_getCurrentProcess(), access, slot) == 0) {
      throw StateError("this process's access token could not be opened");
    }
    token = slot.value;
    return use(token);
  } finally {
    if (token != 0) closeHandle(token);
    _free(slot);
  }
}

SystemFolder _knownLocalAppData() =>
    _withOwnToken(_tokenForKnownFolder, (token) {
      final id = _alloc(16);
      final path = _pointerSlot<Uint16>();
      try {
        id.asTypedList(16).setAll(0, _folderIdLocalAppData);
        final int result;
        String? folder;
        try {
          result = _shGetKnownFolderPath(id, 0, token, path);
          if (result >= 0 && path.value.address != 0) {
            folder = _readUtf16(path.value);
          }
        } finally {
          // Freed whether the call succeeded or not (Microsoft Learn).
          if (path.value.address != 0) _coTaskMemFree(path.value.cast());
        }
        if (result < 0) {
          final code = (result & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
          return (folder: null, problem: '$noLocalAppData (0x$code)');
        }
        if (folder == null || folder.isEmpty || !p.windows.isAbsolute(folder)) {
          return (folder: null, problem: noLocalAppData);
        }
        return (folder: folder, problem: null);
      } finally {
        _free(id);
        _free(path);
      }
    });

String? _tokenUserSid() => _withOwnToken(_tokenQuery, (token) {
  const size = 256;
  final info = _alloc(size);
  final returned = _alloc(4).cast<Uint32>();
  try {
    if (_getTokenInformation(token, _tokenUser, info, size, returned) == 0) {
      return null;
    }
    // `TOKEN_USER` is a `SID_AND_ATTRIBUTES`: the SID's pointer first.
    return _sidText(info.cast<Pointer<Uint8>>().value);
  } finally {
    _free(info);
    _free(returned);
  }
});

/// The SID at [sid] as text; null when it can't be told.
String? _sidText(Pointer<Uint8> sid) {
  if (sid.address == 0) return null;
  final text = _pointerSlot<Uint16>();
  try {
    if (_convertSidToStringSid(sid, text) == 0) return null;
    try {
      return _readUtf16(text.value);
    } finally {
      localFree(text.value.cast());
    }
  } finally {
    _free(text);
  }
}

String? _systemWindowsFolder() {
  var size = 261;
  for (var tries = 0; tries < 2; tries++) {
    final buffer = _alloc(size * 2).cast<Uint16>();
    try {
      final length = _getSystemWindowsDirectory(buffer, size);
      if (length == 0) return null;
      if (length < size) {
        return String.fromCharCodes(buffer.asTypedList(length));
      }
      size = length + 1;
    } finally {
      _free(buffer);
    }
  }
  return null;
}

String? _machineGuid() {
  final key = _utf16(r'SOFTWARE\Microsoft\Cryptography');
  final value = _utf16('MachineGuid');
  const size = 256;
  final data = _alloc(size);
  final bytes = _alloc(4).cast<Uint32>()..value = size;
  try {
    final result = _regGetValue(
      _hkeyLocalMachine,
      key,
      value,
      _regStringFrom64BitView,
      nullptr,
      data,
      bytes,
    );
    if (result != 0) return null;
    return _hexId(_readUtf16(data.cast()));
  } finally {
    _free(key);
    _free(value);
    _free(data);
    _free(bytes);
  }
}

/// [text] (a GUID or UUID, any letter case, with or without dashes) as 32
/// lower-case hex characters; null when it is not one.
String? _hexId(String text) {
  final hex = text.trim().toLowerCase().replaceAll('-', '');
  return RegExp(r'^[0-9a-f]{32}$').hasMatch(hex) ? hex : null;
}

/// A path the security calls and `CreateDirectoryW` take whatever its length:
/// with `\\?\` (`\\?\UNC\` for `\\server\share`) when it is 248 characters
/// or longer.
String windowsLongPath(String path) {
  if (path.length < 248 || path.startsWith(r'\\?\')) return path;
  final full = p.windows.normalize(path);
  if (full.startsWith(r'\\')) return '\\\\?\\UNC\\${full.substring(2)}';
  return '\\\\?\\$full';
}

/// One access rule of a folder's access list, as Windows keeps it: its
/// `type` (0 allows, 1 denies, others are kinds Appstein does not read), its
/// `flags` (inheritance), its access `mask`, and the SID it is for, as text
/// (null for a kind whose SID is not read).
typedef WindowsAce = ({int type, int flags, int mask, String? sid});

/// Who owns a folder on Windows and its access list (`daclPresent` false
/// for a NULL list, which lets everyone do everything).
typedef WindowsAccess = ({
  String? owner,
  bool daclPresent,
  List<WindowsAce> aces,
});

/// The owner and access list of [path] (Windows, `GetNamedSecurityInfoW`; a
/// link is followed); null when they can't be read, and off Windows.
WindowsAccess? windowsAccessOf(String path) {
  if (!Platform.isWindows) return null;
  final name = _utf16(windowsLongPath(path));
  final owner = _pointerSlot<Uint8>();
  final dacl = _pointerSlot<Uint8>();
  final descriptor = _pointerSlot<Uint8>();
  try {
    final result = _getNamedSecurityInfo(
      name,
      1, // SE_FILE_OBJECT
      1 | 4, // OWNER_ | DACL_SECURITY_INFORMATION
      owner,
      nullptr,
      dacl,
      nullptr,
      descriptor,
    );
    if (result != 0) return null;
    try {
      final aces = <WindowsAce>[];
      final list = dacl.value;
      if (list.address != 0) {
        final count = (list + 4).cast<Uint16>().value;
        var at = list + 8;
        for (var i = 0; i < count; i++) {
          final type = at.value;
          final flags = (at + 1).value;
          final size = (at + 2).cast<Uint16>().value;
          final mask = (at + 4).cast<Uint32>().value;
          aces.add((
            type: type,
            flags: flags,
            mask: mask,
            sid: type == 0 || type == 1 ? _sidText(at + 8) : null,
          ));
          if (size == 0) break;
          at = at + size;
        }
      }
      return (
        owner: _sidText(owner.value),
        daclPresent: list.address != 0,
        aces: aces,
      );
    } finally {
      localFree(descriptor.value);
    }
  } finally {
    _free(name);
    _free(owner);
    _free(dacl);
    _free(descriptor);
  }
}

/// The access list of a folder only the user [userSid], the system and the
/// administrators can use, inherited by everything made in it, and not by
/// what is above it (protected).
String privateFolderSddl(String userSid) =>
    'D:P(A;OICI;FA;;;$userSid)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)';

/// [privateFolderSddl] as a security descriptor, given to [use]; freed after.
T _withPrivateDescriptor<T>(
  String userSid,
  T Function(Pointer<Uint8> descriptor) use,
) {
  final sddl = _utf16(privateFolderSddl(userSid));
  final descriptor = _pointerSlot<Uint8>();
  try {
    if (_sddlToDescriptor(sddl, 1, descriptor, nullptr) == 0) {
      throw StateError('the access list could not be made');
    }
    try {
      return use(descriptor.value);
    } finally {
      localFree(descriptor.value);
    }
  } finally {
    _free(sddl);
    _free(descriptor);
  }
}

/// Makes the folder [path] (Windows) with the access list of
/// [privateFolderSddl] from its first moment (`CreateDirectoryW` with a
/// security descriptor). Throws a [FileSystemException] when it can't be
/// made, as when it is there already, and off Windows.
void makePrivateWindowsFolder(String path, String userSid) {
  _windowsOnly(path);
  final made = _withPrivateDescriptor(userSid, (descriptor) {
    final pointer = sizeOf<IntPtr>();
    final attributes = _alloc(3 * pointer);
    final name = _utf16(windowsLongPath(path));
    try {
      attributes.cast<Uint32>().value = 3 * pointer; // nLength
      (attributes + pointer).cast<IntPtr>().value = descriptor.address;
      return _createDirectory(name, attributes) != 0;
    } finally {
      _free(attributes);
      _free(name);
    }
  });
  if (!made) {
    throw FileSystemException('the private folder could not be made', path);
  }
}

/// Gives the folder [path] (Windows) the access list of [privateFolderSddl],
/// protected from what is above it, as `chmod 700` does off Windows. Throws
/// a [FileSystemException] when that fails (the folder is not the user's,
/// and nobody let the user change its list), and off Windows. A folder whose
/// owner let the user change its list passes this: who owns it is checked
/// apart ([WindowsFolderAccess]'s callers).
void makeWindowsFolderPrivate(String path, String userSid) {
  _windowsOnly(path);
  final result = _withPrivateDescriptor(userSid, (descriptor) {
    final present = _alloc(4).cast<Int32>();
    final defaulted = _alloc(4).cast<Int32>();
    final dacl = _pointerSlot<Uint8>();
    final name = _utf16(windowsLongPath(path));
    try {
      if (_getSecurityDescriptorDacl(descriptor, present, dacl, defaulted) ==
          0) {
        return -1;
      }
      return _setNamedSecurityInfo(
        name,
        1, // SE_FILE_OBJECT
        4 | 0x80000000, // DACL_ | PROTECTED_DACL_SECURITY_INFORMATION
        nullptr,
        nullptr,
        dacl.value,
        nullptr,
      );
    } finally {
      _free(present);
      _free(defaulted);
      _free(dacl);
      _free(name);
    }
  });
  if (result != 0) {
    throw FileSystemException(
      "its access list could not be made the user's only (is it the user's "
      'own?)',
      path,
    );
  }
}

/// The SID of this process's user, read once (lazily) for the process.
final String? _processUserSid = SystemCalls.real.userSid();

/// What the analysis host does to and asks of folders on Windows: the user's
/// SID, a folder made private from its first moment, a folder made private
/// again, and a folder's owner and access list. [real] is the system's
/// (by FFI); tests give their own, so the Windows rules run on every system.
class WindowsFolderAccess {
  /// The calls of the system.
  const WindowsFolderAccess();

  /// The calls of the system this process runs on.
  static const real = WindowsFolderAccess();

  /// The SID of this process's user; null when it can't be read. Read once
  /// for the process.
  String? userSid() => _processUserSid;

  /// [makePrivateWindowsFolder].
  void makePrivate(String path, String userSid) =>
      makePrivateWindowsFolder(path, userSid);

  /// [makeWindowsFolderPrivate].
  void repair(String path, String userSid) =>
      makeWindowsFolderPrivate(path, userSid);

  /// [windowsAccessOf].
  WindowsAccess? accessOf(String path) => windowsAccessOf(path);
}

// ---------------------------------------------------------------------------
// macOS: libSystem, in the process already.

final _libSystem = DynamicLibrary.process();

final _malloc = _libSystem
    .lookupFunction<
      Pointer<Uint8> Function(Size),
      Pointer<Uint8> Function(int)
    >('malloc');
final _freeNative = _libSystem
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >('free');
final _geteuid = _libSystem.lookupFunction<Uint32 Function(), int Function()>(
  'geteuid',
);
final _confstrCall = _libSystem
    .lookupFunction<
      Size Function(Int32 name, Pointer<Uint8> buffer, Size length),
      int Function(int name, Pointer<Uint8> buffer, int length)
    >('confstr');
final _getpwuidR = _libSystem
    .lookupFunction<
      Int32 Function(
        Uint32 uid,
        Pointer<Uint8> pwd,
        Pointer<Uint8> buffer,
        Size size,
        Pointer<Pointer<Uint8>> result,
      ),
      int Function(
        int uid,
        Pointer<Uint8> pwd,
        Pointer<Uint8> buffer,
        int size,
        Pointer<Pointer<Uint8>> result,
      )
    >('getpwuid_r');
final _gethostuuid = _libSystem
    .lookupFunction<
      Int32 Function(Pointer<Uint8> id, Pointer<Int64> wait),
      int Function(Pointer<Uint8> id, Pointer<Int64> wait)
    >('gethostuuid');

/// `_CS_DARWIN_USER_DIR` (Apple Libc, `include/unistd.h`).
const _csDarwinUserDir = 65536;

/// `_CS_DARWIN_USER_TEMP_DIR`.
const _csDarwinUserTempDir = 65537;

/// `confstr(name)`; null when it fails (it gives 0).
String? _confstr(int name) {
  var size = 1024;
  for (var tries = 0; tries < 2; tries++) {
    final buffer = _alloc(size);
    try {
      final needed = _confstrCall(name, buffer, size);
      if (needed == 0) return null;
      if (needed <= size) return _readUtf8(buffer);
      size = needed;
    } finally {
      _free(buffer);
    }
  }
  return null;
}

/// `ERANGE`: the buffer of `getpwuid_r` is too small.
const _eRange = 34;

/// The home of [uid] from the user database (`getpwuid_r`): `struct passwd`
/// on 64-bit macOS is 72 bytes, with `pw_dir` (a `char *`) at offset 48.
String? _macHome(int uid) {
  const passwdSize = 72;
  const dirAt = 48;
  for (var size = 4096; size <= 1 << 20; size *= 2) {
    final pwd = _alloc(passwdSize);
    final buffer = _alloc(size);
    final result = _pointerSlot<Uint8>();
    try {
      final error = _getpwuidR(uid, pwd, buffer, size, result);
      if (error == _eRange) continue;
      if (error != 0 || result.value.address == 0) return null;
      final dir = (pwd + dirAt).cast<Pointer<Uint8>>().value;
      if (dir.address == 0) return null;
      final home = _readUtf8(dir);
      return p.posix.isAbsolute(home) ? home : null;
    } finally {
      _free(pwd);
      _free(buffer);
      _free(result);
    }
  }
  return null;
}

/// The host UUID (`gethostuuid`, `<unistd.h>`) as 32 hex characters. A zero
/// wait means "wait until it completes" (gethostuuid(2)), so the wait is 1 s:
/// the kernel has the UUID from the platform at once in practice.
String? _hostUuid() {
  final id = _alloc(16);
  final wait = _alloc(16).cast<Int64>();
  try {
    wait.value = 1; // tv_sec
    (wait + 1).value = 0; // tv_nsec
    if (_gethostuuid(id, wait) != 0) return null;
    return [
      for (final byte in id.asTypedList(16))
        byte.toRadixString(16).padLeft(2, '0'),
    ].join();
  } finally {
    _free(id);
    _free(wait.cast());
  }
}
