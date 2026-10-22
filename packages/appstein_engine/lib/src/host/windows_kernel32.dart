import 'dart:ffi';

// The `kernel32` calls that more than one part of the engine makes by FFI
// (`process_identity.dart`, `system_calls.dart`). Not exported. The library is
// opened in a lazy top-level final, so code that imports this loads on every
// system and touches `kernel32` only when it calls it, on Windows.

/// `kernel32.dll`.
final kernel32 = DynamicLibrary.open('kernel32.dll');

/// `LocalAlloc`: memory the caller frees with [localFree].
final localAlloc = kernel32
    .lookupFunction<
      Pointer<Uint8> Function(Uint32 flags, IntPtr bytes),
      Pointer<Uint8> Function(int flags, int bytes)
    >('LocalAlloc');

/// `LocalFree`.
final localFree = kernel32
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Uint8> memory),
      Pointer<Uint8> Function(Pointer<Uint8> memory)
    >('LocalFree');

/// `CloseHandle`.
final closeHandle = kernel32
    .lookupFunction<Int32 Function(IntPtr handle), int Function(int handle)>(
      'CloseHandle',
    );

/// `LPTR`: fixed memory, filled with zeros, for [localAlloc].
const lptr = 0x0040;
