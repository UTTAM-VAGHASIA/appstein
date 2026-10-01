# appstein_protocol

Shared data models for Appstein: SDK facts, configuration, layer rules, severities, the protocol version and the `.appstein/` file formats (`KnowledgeMeta`, `KnowledgeState`, `CuratedNote`, `Toolchain`). It holds data only, and nothing in it touches the machine.

- **May depend on:** no other Appstein package (spec §5.1).
- **Entry point:** `lib/appstein_protocol.dart`.
- **Test:** `cd packages/appstein_protocol; fvm dart test`.
- **How it works:** [architecture](../../docs/guide/architecture.md).
