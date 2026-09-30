<!-- covers: none -->

# Debugging

## `appstein` exits with code 3

Code 3 means Appstein itself failed, not your project. The causes, from [cli](cli.md):

- a bad option, an unknown command, or a `--project` folder with no `pubspec.yaml`;
- an invalid `appstein.yaml`, but no command gets there today: the handler is a safety net for any command that loads the config itself. `doctor` reports an invalid file as a check error, with exit code 1;
- a crash, including an error thrown outside any awaited future.

The error output says which. Run `appstein doctor` first, because most failures are environment problems it explains.

## The analyzer plugin

- `print` does nothing inside a plugin, because it runs in a separate isolate in the analysis server. To see what a rule does, write a test in `packages/appstein_lints/test/` instead (see [testing](testing.md)).
- After changing plugin code, restart the analysis server. In VS Code, run "Dart: Restart Analysis Server". On the command line, each `fvm dart analyze` starts fresh.
- The first analysis after a change is slower, because the server recompiles the plugin.

## Windows paths

Engine tests create temporary folders with a space and a non-ASCII character in the name, because paths like `C:\Users\Jöhn Doe\my app` must work (see [testing](testing.md)). If a test fails only on Windows, suspect how a tool is started. `SystemProcessRunner`, in `packages/appstein_engine/lib/src/host/process_runner.dart`, does not use `runInShell`, because Dart's shell mode doesn't quote an executable path that contains spaces. It starts `.bat` and `.cmd` files directly by their full path, and Windows runs them through `cmd.exe` implicitly. So callers must pass the full path that `findExecutable` returns: a bare name such as `fvm` only finds `.exe` files.

## The knowledge graph isn't updating

graphify's hooks rebuild the graph in the background after a commit or a branch switch, and our hooks add merges, pulls and rebases (see [docs-tooling](docs-tooling.md#git-hooks)). If `graphify-out/` seems stale:

1. Run `graphify hook status`. It should list `post-commit` and `post-checkout` as installed.
2. Read the rebuild log at `~/.cache/graphify-rebuild.log`. A background rebuild prints its errors there, not in your terminal.
3. Check that `GRAPHIFY_SKIP_HOOK` isn't set to `1` in your environment. It turns off every graph rebuild, including ours after a merge or rebase.
4. Re-run `fvm dart run tool/install_hooks.dart`. It reinstalls graphify's hooks and our blocks, and it is safe to run again.

Two more things to know: graphify's hooks do nothing in a linked git worktree, and they rebuild only the code structure. The semantic parts of the graph need a full `/graphify . --update`.

## The docs hook prints warnings after a commit

After a commit you may see lines starting with `warning:`, then:

```text
The developer guide may need attention (2 warning(s)). CI fails on these. See docs/guide/docs-tooling.md.
```

**What they mean.** The post-commit hook ran the guide check on the commit you just made (`--since HEAD~1`). It compares the working tree with `HEAD~1`, not just the commit, so uncommitted and untracked work counts too. After a partial commit, it can warn about files you haven't committed yet, and an uncommitted page edit can hide a warning that CI would give if you pushed without it. Each warning is a problem CI will fail on, for example:

- a file you changed is covered by a page you didn't change;
- a generated section is out of date;
- a new source file is covered by no page, or a link is broken.

**They never block a commit.** The commit already exists when the hook runs, and the hook always exits 0. The warning is there so you hear about the problem before CI does.

**How to fix or confirm.**

- Update the page, or run `fvm dart run tool/gen_docs.dart`, then commit again.
- If the page is still right, add a `Docs-Checked: <page> - <reason>` trailer to the commit message, for example with `git commit --amend`.

[docs-tooling](docs-tooling.md) explains each check and the trailer.

**To skip the hook once,** set `APPSTEIN_SKIP_DOCS_HOOK=1` for that commit. CI still runs the check.
