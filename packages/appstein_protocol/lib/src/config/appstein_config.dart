import '../severity.dart';

/// Project configuration from `appstein.yaml` (spec §7).
///
/// Every field has a default, so an empty file is valid. The JSON form uses
/// the same key names as the YAML file.
final class AppsteinConfig {
  /// Creates a configuration. Omitted sections use their defaults.
  const AppsteinConfig({
    this.formatVersion = 1,
    this.packs = const PacksConfig(),
    this.delta = const DeltaConfig(),
    this.verify = const VerifyConfig(),
    this.docs = const DocsConfig(),
    this.packages = const PackagesConfig(),
    this.integrations = const IntegrationsConfig(),
  });

  /// The config format version (the `appstein:` key).
  final int formatVersion;

  /// Which stack and platform packs the project uses.
  final PacksConfig packs;

  /// How far back the version delta reaches.
  final DeltaConfig delta;

  /// Verifier settings.
  final VerifyConfig verify;

  /// Human documentation settings (spec §6.9).
  final DocsConfig docs;

  /// Package gate settings.
  final PackagesConfig packages;

  /// Agent and optional integrations.
  final IntegrationsConfig integrations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'appstein': formatVersion,
    'packs': packs.toJson(),
    'delta': delta.toJson(),
    'verify': verify.toJson(),
    'docs': docs.toJson(),
    'packages': packages.toJson(),
    'integrations': integrations.toJson(),
  };
}

/// The `packs:` section.
final class PacksConfig {
  /// Creates the section.
  const PacksConfig({
    this.stack = 'official_mvvm',
    this.platforms = const ['android', 'ios'],
  });

  /// The stack pack, such as `official_mvvm`.
  final String stack;

  /// The platform packs, such as `android` and `ios`.
  final List<String> platforms;

  /// The JSON form.
  Map<String, Object?> toJson() => {'stack': stack, 'platforms': platforms};
}

/// The `delta:` section.
final class DeltaConfig {
  /// Creates the section.
  const DeltaConfig({this.baseline = '3.16'});

  /// Curated notes since this Flutter version, such as `3.16` (spec §6.4);
  /// deprecations and migrations are listed whatever their age.
  final String baseline;

  /// The JSON form.
  Map<String, Object?> toJson() => {'baseline': baseline};
}

/// The `verify:` section.
final class VerifyConfig {
  /// Creates the section.
  const VerifyConfig({
    this.fastTimeoutSeconds = 20,
    this.buildOnFull = true,
    this.severity = const {},
  });

  /// Safety cap for a fast verify run. The target is under 5 s (spec §15).
  final int fastTimeoutSeconds;

  /// Whether `verify --full` runs real debug builds.
  final bool buildOnFull;

  /// Per-check severity overrides, keyed by check ID.
  final Map<String, Severity> severity;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'fast_timeout_seconds': fastTimeoutSeconds,
    'build_on_full': buildOnFull,
    'severity': {for (final e in severity.entries) e.key: e.value.name},
  };
}

/// The `docs:` section.
final class DocsConfig {
  /// Creates the section.
  const DocsConfig({this.enabled = true, this.path = 'docs/app'});

  /// Whether human docs are rendered.
  final bool enabled;

  /// Where they go, relative to the project root, with `/` separators.
  final String path;

  /// The JSON form.
  Map<String, Object?> toJson() => {'enabled': enabled, 'path': path};
}

/// The `packages:` section.
final class PackagesConfig {
  /// Creates the section.
  const PackagesConfig({
    this.staleAfterMonths = 12,
    this.allow = const [],
    this.deny = const [],
  });

  /// A package with no release for this many months gets a warning.
  final int staleAfterMonths;

  /// Packages exempt from the maintenance warning.
  final List<String> allow;

  /// Packages that are always blocked.
  final List<String> deny;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'stale_after_months': staleAfterMonths,
    'allow': allow,
    'deny': deny,
  };
}

/// The `integrations:` section.
final class IntegrationsConfig {
  /// Creates the section.
  const IntegrationsConfig({
    this.agents = const ['claude', 'codex'],
    this.graphifyExport = false,
    this.developerKnowledgeMcp = false,
  });

  /// The agents `integrate` sets up.
  final List<String> agents;

  /// Whether `sync` also writes a graphify export (spec §16).
  final bool graphifyExport;

  /// Whether the Google Developer Knowledge MCP is enabled (spec §16).
  final bool developerKnowledgeMcp;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'agents': agents,
    'graphify_export': graphifyExport,
    'developer_knowledge_mcp': developerKnowledgeMcp,
  };
}
