# Debugging

## `appstein` exits with code 3

Code 3 means Appstein itself failed: a bad option, an invalid `appstein.yaml`, or a crash. The error output says which. Run `appstein doctor` first, because most failures are environment problems it explains.

## The analyzer plugin

- `print` does nothing inside a plugin, because it runs in a separate isolate in the analysis server. To see what a rule does, write a test in `packages/appstein_lints/test/` instead.
- After changing plugin code, restart the analysis server. In VS Code, run "Dart: Restart Analysis Server". On the command line, each `fvm dart analyze` starts fresh.
- The first analysis after a change is slower, because the server recompiles the plugin.

## Windows paths

Engine tests create temporary folders with a space and a non-ASCII character in the name, because paths like `C:\Users\Jöhn Doe\my app` must work. If a test fails only on Windows, suspect how a tool is started. `SystemProcessRunner`, in `packages/appstein_engine/lib/src/host/process_runner.dart`, does not use `runInShell`, because Dart's shell mode doesn't quote an executable path that contains spaces. It starts `.bat` and `.cmd` files directly by their full path, and Windows runs them through `cmd.exe` implicitly. So callers must pass the full path that `findExecutable` returns: a bare name such as `fvm` only finds `.exe` files.
