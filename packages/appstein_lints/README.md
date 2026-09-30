# appstein_lints

Appstein's analyzer plugin. It runs inside the Dart analyzer, so its rules show up in every IDE and agent. It has one rule today, `layer_imports`.

- **May depend on:** `appstein_protocol` only, among Appstein's packages (spec §5.1). It never imports packs: it reads layer rules from the top-level `appstein_lints:` section of `analysis_options.yaml`, where stack packs will write them (spec §9.6).
- **Entry point:** `lib/main.dart` (the `plugin` variable the analysis server loads).
- **Test:** `cd packages/appstein_lints; fvm dart test`.
- **How it works:** [lints](../../docs/guide/lints.md).
