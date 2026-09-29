# appstein_engine

Everything Appstein does, with no command-line code: host access, `appstein.yaml`, Flutter SDK detection and `doctor`. Later slices add knowledge, verification and the MCP server.

- **May depend on:** `appstein_protocol` only (spec §5.1).
- **Entry point:** `lib/appstein_engine.dart`.
- **Test:** `cd packages/appstein_engine; fvm dart test`. Tests tagged `integration` use the real machine: `fvm dart test --run-skipped --tags integration`.
