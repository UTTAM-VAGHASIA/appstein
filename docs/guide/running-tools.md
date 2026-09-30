<!-- covers: packages/appstein_engine/lib/src/host/** -->

# Reading the machine and running tools

Doctor and the SDK lookups read environment variables, search the PATH and run tools such as `java -version`. This page explains the small layer in `packages/appstein_engine/lib/src/host/` that does all of that, and why it is built the way it is.

## `HostEnvironment`

[`host_environment.dart`](../../packages/appstein_engine/lib/src/host/host_environment.dart) describes a machine: the OS (`HostOs`), the environment variables and the working folder. `HostEnvironment.current()` reads the real ones when the CLI starts.

**It is the engine's only view of the OS, the environment variables and the working folder.** Outside this class, engine code doesn't read `Platform.environment` or `Directory.current`. That is what makes the engine testable: a test builds a `HostEnvironment` with exactly the variables it wants, and the code under test can't see the real machine's `JAVA_HOME` or PATH. Two narrow exceptions are described below: a tool started by bare name, and the Windows tree kill in `SystemProcessRunner`.

- **`variable(name)`** returns a variable's value, or null when it is unset **or empty**. An empty `JAVA_HOME` means "not set" to every caller.
- **Names are case-insensitive on Windows.** Windows treats `Path` and `PATH` as the same variable, so on Windows `variable` falls back to a case-insensitive match. Elsewhere, names are case-sensitive, as the OS treats them.
- **`homeDir`** is `USERPROFILE` on Windows and `HOME` elsewhere.
- **`pathEntries`** splits PATH on `;` (Windows) or `:` (elsewhere), trims each entry, removes the quotes Windows allows around one (`"C:\Program Files\Git\cmd"`), and drops empty entries. Kept, an empty entry would make `findExecutable` look in the current folder, as a POSIX shell does. Dropped, a tool is never "found" just because it sits in the folder you ran Appstein from.

## `findExecutable`

[`executable_finder.dart`](../../packages/appstein_engine/lib/src/host/executable_finder.dart) finds a command on the PATH the way a shell does, and returns its full path, or null when it isn't installed. The PATH is read in order, and the first match wins.

- **On Windows** it tries each extension in `PATHEXT` in order (`.COM;.EXE;.BAT;.CMD` when the variable isn't set). So `findExecutable('fvm', …)` finds `fvm.bat`. A name that already ends in one of those extensions is tried as it is.
- **Elsewhere** the file must have an execute bit, as for a shell. A file without one is passed over.

## `ProcessRunner` and `SystemProcessRunner`

[`process_runner.dart`](../../packages/appstein_engine/lib/src/host/process_runner.dart) holds the interface, `ProcessRunner`, and the real implementation, `SystemProcessRunner`. Engine code only ever sees the interface, so tests pass a fake.

### The contract

`run(executable, arguments, {timeout, environment})`:

- **It never throws for a missing or failing tool.** Doctor's whole job is to report missing tools, so "not installed" is a normal answer, not an exception.
- **The default timeout is 20 s.** A check can pass its own; the agent check uses 10 s.

The answer is a `RunResult` in one of three states:

| State | Built with | `exitCode` | `stdout`, `stderr` |
|---|---|---|---|
| Ran to completion | `RunResult(...)` | The tool's exit code | What it printed |
| Could not start (not installed, not executable) | `RunResult.notStarted` | `-1` | Empty; `stderr` holds the reason |
| Killed for running too long | `RunResult.timedOut` | `-1` | What it printed so far; `stderr` starts with "Timed out after N s" |

`ok` is true only when the tool started, didn't time out and exited with `0`. Most callers only need `ok`.

### How `SystemProcessRunner` starts a tool

- **No `runInShell`.** On Windows, Dart's shell mode passes the command to `cmd.exe` without quoting the executable path, so a path with a space, such as `C:\Users\Jöhn Doe\fvm\fvm.bat`, breaks at the space. The runner starts the tool directly instead, and Dart quotes each argument.
- **`.bat` and `.cmd` files by full path.** Started directly, Windows runs a batch file through `cmd.exe` by itself. But a bare name only finds `.exe` files, so `run('fvm', …)` reports "not started" even when `fvm.bat` is on PATH. Callers pass the full path from `findExecutable`.
- **Bare names use the real PATH.** A tool started by bare name, such as `xcodebuild`, `pod` or `reg`, is found by the OS on this process's own PATH, not on the `HostEnvironment`'s. That is one of the two exceptions above.

### Timeouts and the Windows tree kill

When a tool runs past its timeout, the runner kills it. On Windows, `Process.kill` isn't enough: for a `.bat` or `.cmd` tool it ends only the `cmd.exe` that runs the script, and the program the script started keeps running. So on Windows the runner first runs `taskkill /PID <pid> /T /F`, which ends the whole process tree. It starts `taskkill.exe` by its full path under `SystemRoot`, `%SystemRoot%\System32\taskkill.exe` (with `C:\Windows` if `SystemRoot` is unset), never by bare name, so no other `taskkill.exe` (for example one in the working folder or earlier on the PATH) runs instead. The kill reads the real OS and `SystemRoot` from the process itself, not from `HostEnvironment`: that is the second exception. Then it calls `Process.kill` as well.

**Known gaps**, listed for slice 1d in the slice 1a plan's [Carried to later slices](../superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md#carried-to-later-slices): on POSIX, a timed-out tool's grandchildren aren't killed, and on Windows `taskkill /T` could kill a Gradle daemon the tool started.

### Reading output

- **The pipes are drained with a bound.** A batch file's child programs can keep stdout and stderr open after the batch file itself has exited. After the tool exits, the runner waits at most 2 s for the pipes to close, then stops reading. Without the bound, an open pipe would keep `appstein` itself alive, and doctor would hang.
- **Invalid bytes are tolerated.** Output is decoded as UTF-8 once, at the end, with invalid bytes replaced instead of throwing. A JDK set to another language can print text that isn't valid UTF-8.

## `resolveLinks`

[`file_links.dart`](../../packages/appstein_engine/lib/src/host/file_links.dart) has one function, `resolveLinks`: it follows symbolic links, and junctions on Windows, to the real file or folder. When the path can't be resolved, for example because it doesn't exist, it returns the path unchanged instead of throwing.

The lookups need it because tools are often installed as links: FVM's `.fvm/flutter_sdk` is a link (on Windows, often a junction), and `flutter` or `adb` on the PATH may be a link into the SDK. The SDK folder is found from the real location, not the link's. The Dart check also resolves both paths before it decides whether the `dart` on PATH belongs to the project's SDK. See [sdk-lookups](sdk-lookups.md).

## Testing code that uses these

Tests pass a `fakeEnvironment` and a `FakeProcessRunner` instead of the real ones, and use real temporary folders for files. The runner itself is tested with real processes, including a script whose child keeps the pipes open. [testing](testing.md) explains the helpers.
