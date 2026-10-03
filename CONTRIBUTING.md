# Contributing to Appstein

Thanks for your interest. Appstein is pre-alpha: the design is settled in the [spec](docs/superpowers/specs/2026-09-29-appstein-design.md), and the code is built one slice at a time ([progress](docs/superpowers/progress.yaml)). Small fixes are welcome any time. For anything bigger, open an issue first, so we agree on the approach before you write code.

## Ground rules

- **The spec is the source of truth.** If the code and the spec disagree, say so in an issue. Don't change the spec in a pull request without talking about it first.
- **Appstein never touches agent credentials, and never encodes Play Store or App Store policies** (spec §2.3, §4). Pull requests that do are declined.
- **Windows is first-class:** paths with spaces, drive letters, PowerShell. CI runs on Linux, macOS and Windows.

## Set up

Follow [Set up](docs/guide/README.md#set-up) in the developer guide: FVM, `fvm dart pub get`, and the git hooks. Run every command through FVM (`fvm dart …`, `fvm flutter …`); the `dart` on your PATH may be a different SDK.

graphify (`uv tool install graphifyy`) is optional. It keeps the repo's knowledge graph current for coding agents; without it, `install_hooks` skips the graph hooks and says so.

## Check your change

```powershell
fvm dart format .
fvm dart analyze --fatal-infos
fvm dart test test                                  # the repo tooling
cd packages/appstein_engine; fvm dart test; cd ../..  # and each package you changed
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

## Docs travel with the code

Every source file is explained by a page in [`docs/guide/`](docs/guide/README.md); the `<!-- covers: -->` comment at the top of a page lists its files. When you change a file, update its page in the same pull request. If the page is still right, say so with a trailer in your commit message:

```text
Docs-Checked: cli.md - the new flag is hidden and internal
```

Every public API has a `///` doc comment. See [docs-tooling](docs/guide/docs-tooling.md) for the checks.

## Pull requests

- One topic per pull request, with tests. Write the test first when you can.
- Say what changed and why. The pull request template lists the checks.
- Coding agents working on this repo follow [`AGENTS.md`](AGENTS.md).

## License of contributions

Appstein is licensed under the [Apache License 2.0](LICENSE). Unless you say otherwise, a contribution you submit is under the same license (section 5 of the license). There is no CLA.
