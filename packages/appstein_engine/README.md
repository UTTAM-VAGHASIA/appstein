# appstein_engine

Everything Appstein does, with no command-line code: host access, `appstein.yaml`, the Flutter SDK, JDK and Android SDK lookups, `doctor`, and the knowledge store with `sync`'s platform layer (the toolchain matrix and the curated notes). Later slices add the project map, verification and the MCP server.

- **May depend on:** `appstein_protocol` only, among Appstein's packages (spec §5.1).
- **Entry point:** `lib/appstein_engine.dart`.
- **Test:** `cd packages/appstein_engine; fvm dart test`. Tests tagged `integration` use the real machine: `fvm dart test --run-skipped --tags integration`.
- **How it works:** [doctor](../../docs/guide/doctor.md), [sdk-lookups](../../docs/guide/sdk-lookups.md), [knowledge-store](../../docs/guide/knowledge-store.md), [toolchain](../../docs/guide/toolchain.md), [running-tools](../../docs/guide/running-tools.md) and [config](../../docs/guide/config.md).
