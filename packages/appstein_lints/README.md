# appstein_lints

Appstein's analyzer plugin. It runs inside the Dart analyzer, so its rules show up in every IDE and agent.

- **May depend on:** `appstein_protocol` only (spec §5.1). It never imports packs; stack packs write their layer rules into the project's `analysis_options.yaml`.
- **Entry point:** `lib/main.dart` (the `plugin` variable the analysis server loads).
- **Test:** `cd packages/appstein_lints; fvm dart test`.
