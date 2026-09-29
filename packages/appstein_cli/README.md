# appstein_cli

The `appstein` command. It is a thin layer: it parses arguments, calls `appstein_engine` and prints the results.

- **May depend on:** `appstein_engine` and `appstein_protocol` (spec §5.1).
- **Entry points:** `bin/appstein.dart` and `runAppstein()` in `lib/appstein_cli.dart`.
- **Test:** `cd packages/appstein_cli; fvm dart test`.
