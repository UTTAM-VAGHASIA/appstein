import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../text/edit_distance.dart';

/// The name of Appstein's project configuration file.
const configFileName = 'appstein.yaml';

/// The `appstein:` format version this build reads.
const supportedConfigFormat = 1;

/// Stack packs this build knows. The list grows as packs are added.
const knownStacks = ['official_mvvm'];

/// Target platforms supported in M1.
const knownPlatforms = ['android', 'ios'];

/// Agents that `integrate` can set up in M1.
const knownAgents = ['claude', 'codex'];

/// Thrown when `appstein.yaml` is invalid.
///
/// Carries the position, so the message points at the exact line.
final class ConfigException implements Exception {
  /// Creates a config error at an optional position.
  ConfigException(this.message, {this.sourcePath, this.line, this.column});

  /// What is wrong, written for the person editing the file.
  final String message;

  /// The file the error is in, when known.
  final String? sourcePath;

  /// The 1-based line, when known.
  final int? line;

  /// The 1-based column, when known.
  final int? column;

  @override
  String toString() {
    final position = StringBuffer();
    if (sourcePath != null) position.write(sourcePath);
    if (line != null) {
      if (position.isNotEmpty) position.write(':');
      position.write(line);
      if (column != null) position.write(':$column');
    }
    return position.isEmpty ? message : '$position: $message';
  }
}

/// Loads `appstein.yaml` from [projectRoot].
///
/// Returns null when the file doesn't exist, meaning the project isn't set
/// up with Appstein yet. Throws [ConfigException] when the file is invalid.
AppsteinConfig? loadConfig(String projectRoot) {
  final file = File(p.join(projectRoot, configFileName));
  if (!file.existsSync()) return null;
  final String content;
  try {
    content = file.readAsStringSync();
  } on FileSystemException catch (error) {
    // For example a file that isn't UTF-8, or one that is locked.
    throw ConfigException(
      'Could not read $configFileName: ${error.message}',
      sourcePath: file.path,
    );
  }
  return parseConfig(content, sourcePath: file.path);
}

/// Parses and validates the text of an `appstein.yaml` file.
///
/// Every key has a default, so an empty file is valid. Unknown keys are
/// errors, with a "did you mean" hint for likely typos.
AppsteinConfig parseConfig(String content, {String? sourcePath}) {
  final YamlNode root;
  try {
    root = loadYamlNode(
      // Windows PowerShell 5.1 writes a UTF-8 byte order mark.
      content.startsWith('﻿') ? content.substring(1) : content,
      sourceUrl: sourcePath == null ? null : p.toUri(sourcePath),
    );
  } on YamlException catch (error) {
    final span = error.span;
    throw ConfigException(
      error.message,
      sourcePath: sourcePath,
      line: span == null ? null : span.start.line + 1,
      column: span == null ? null : span.start.column + 1,
    );
  }
  if (root is YamlScalar && root.value == null) return const AppsteinConfig();
  return _ConfigReader(sourcePath).read(root);
}

final class _ConfigReader {
  _ConfigReader(this.sourcePath);

  final String? sourcePath;

  static final _checkIdPattern = RegExp(
    r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
  );
  static final _packageNamePattern = RegExp(r'^[a-z_][a-z0-9_]*$');
  static final _flutterMinorPattern = RegExp(r'^\d+\.\d+$');

  AppsteinConfig read(YamlNode root) {
    final top = _map(root, 'appstein.yaml');
    _checkKeys(top, 'appstein.yaml', const [
      'appstein',
      'packs',
      'delta',
      'verify',
      'docs',
      'packages',
      'integrations',
    ]);
    final format = _int(
      top,
      'appstein',
      'appstein',
      fallback: supportedConfigFormat,
    );
    if (format != supportedConfigFormat) {
      throw _error(
        top.nodes['appstein']!,
        'Config format $format is not supported; this Appstein reads '
        'format $supportedConfigFormat.',
      );
    }
    return AppsteinConfig(
      packs: _packs(_section(top, 'packs')),
      delta: _delta(_section(top, 'delta')),
      verify: _verify(_section(top, 'verify')),
      docs: _docs(_section(top, 'docs')),
      packages: _packages(_section(top, 'packages')),
      integrations: _integrations(_section(top, 'integrations')),
    );
  }

  PacksConfig _packs(YamlMap? map) {
    const defaults = PacksConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'packs', const ['stack', 'platforms']);
    return PacksConfig(
      stack: _string(
        map,
        'stack',
        'packs.stack',
        fallback: defaults.stack,
        oneOf: knownStacks,
      ),
      platforms: _stringList(
        map,
        'platforms',
        'packs.platforms',
        fallback: defaults.platforms,
        oneOf: knownPlatforms,
        nonEmpty: true,
      ),
    );
  }

  DeltaConfig _delta(YamlMap? map) {
    if (map == null) return const DeltaConfig();
    _checkKeys(map, 'delta', const ['baseline']);
    final node = map.nodes['baseline'];
    if (node == null || _isNull(node)) return const DeltaConfig();
    final value = node.value;
    if (value is num) {
      throw _error(
        node,
        'delta.baseline must be quoted, like "3.16". '
        'Unquoted, YAML reads 3.20 as the number 3.2.',
      );
    }
    if (value is! String || !_flutterMinorPattern.hasMatch(value)) {
      throw _error(
        node,
        'delta.baseline must be a Flutter version like "3.16".',
      );
    }
    return DeltaConfig(baseline: value);
  }

  VerifyConfig _verify(YamlMap? map) {
    const defaults = VerifyConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'verify', const [
      'fast_timeout_seconds',
      'build_on_full',
      'severity',
    ]);
    final severity = <String, Severity>{};
    final severityMap = _section(map, 'severity', where: 'verify.severity');
    if (severityMap != null) {
      for (final entry in severityMap.nodes.entries) {
        final keyNode = entry.key as YamlNode;
        final id = keyNode.value;
        if (id is! String || !_checkIdPattern.hasMatch(id)) {
          throw _error(
            keyNode,
            'verify.severity: "$id" is not a check ID. '
            'Check IDs look like "ui.no_hardcoded_colors".',
          );
        }
        final level = entry.value.value;
        final matches = Severity.values.where((s) => s.name == level);
        if (matches.isEmpty) {
          throw _error(
            entry.value,
            'verify.severity.$id must be error, warning or info.',
          );
        }
        severity[id] = matches.single;
      }
    }
    return VerifyConfig(
      fastTimeoutSeconds: _int(
        map,
        'fast_timeout_seconds',
        'verify.fast_timeout_seconds',
        fallback: defaults.fastTimeoutSeconds,
      ),
      buildOnFull: _bool(
        map,
        'build_on_full',
        'verify.build_on_full',
        fallback: defaults.buildOnFull,
      ),
      severity: Map.unmodifiable(severity),
    );
  }

  DocsConfig _docs(YamlMap? map) {
    const defaults = DocsConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'docs', const ['enabled', 'path']);
    var docsPath = defaults.path;
    final node = map.nodes['path'];
    if (node != null && !_isNull(node)) {
      final raw = node.value;
      if (raw is! String || raw.trim().isEmpty) {
        throw _error(node, 'docs.path must be a folder path, like docs/app.');
      }
      if (p.posix.isAbsolute(raw) || p.windows.isAbsolute(raw)) {
        throw _error(
          node,
          'docs.path must be relative to the project root, not absolute.',
        );
      }
      final normalized = p.posix.normalize(raw.replaceAll(r'\', '/'));
      if (normalized == '.' ||
          normalized == '..' ||
          normalized.startsWith('../')) {
        throw _error(node, 'docs.path must be a folder inside the project.');
      }
      docsPath = normalized;
    }
    return DocsConfig(
      enabled: _bool(
        map,
        'enabled',
        'docs.enabled',
        fallback: defaults.enabled,
      ),
      path: docsPath,
    );
  }

  PackagesConfig _packages(YamlMap? map) {
    const defaults = PackagesConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'packages', const ['stale_after_months', 'allow', 'deny']);
    return PackagesConfig(
      staleAfterMonths: _int(
        map,
        'stale_after_months',
        'packages.stale_after_months',
        fallback: defaults.staleAfterMonths,
      ),
      allow: _stringList(
        map,
        'allow',
        'packages.allow',
        fallback: defaults.allow,
        pattern: _packageNamePattern,
      ),
      deny: _stringList(
        map,
        'deny',
        'packages.deny',
        fallback: defaults.deny,
        pattern: _packageNamePattern,
      ),
    );
  }

  IntegrationsConfig _integrations(YamlMap? map) {
    const defaults = IntegrationsConfig();
    if (map == null) return defaults;
    _checkKeys(map, 'integrations', const [
      'agents',
      'graphify_export',
      'developer_knowledge_mcp',
    ]);
    return IntegrationsConfig(
      agents: _stringList(
        map,
        'agents',
        'integrations.agents',
        fallback: defaults.agents,
        oneOf: knownAgents,
      ),
      graphifyExport: _bool(
        map,
        'graphify_export',
        'integrations.graphify_export',
        fallback: defaults.graphifyExport,
      ),
      developerKnowledgeMcp: _bool(
        map,
        'developer_knowledge_mcp',
        'integrations.developer_knowledge_mcp',
        fallback: defaults.developerKnowledgeMcp,
      ),
    );
  }

  ConfigException _error(YamlNode node, String message) => ConfigException(
    message,
    sourcePath: sourcePath,
    line: node.span.start.line + 1,
    column: node.span.start.column + 1,
  );

  bool _isNull(YamlNode node) => node is YamlScalar && node.value == null;

  YamlMap _map(YamlNode node, String where) {
    if (node is YamlMap) return node;
    throw _error(node, '$where must be a map of keys and values.');
  }

  YamlMap? _section(YamlMap parent, String key, {String? where}) {
    final node = parent.nodes[key];
    if (node == null || _isNull(node)) return null;
    return _map(node, where ?? key);
  }

  void _checkKeys(YamlMap map, String where, List<String> allowed) {
    for (final keyNode in map.nodes.keys.cast<YamlNode>()) {
      final key = keyNode.value;
      if (key is String && allowed.contains(key)) continue;
      final suggestion = key is String ? closestMatch(key, allowed) : null;
      final hint = suggestion == null ? '' : ' Did you mean "$suggestion"?';
      throw _error(
        keyNode,
        'Unknown key "$key" in $where.$hint '
        'Allowed keys: ${allowed.join(', ')}.',
      );
    }
  }

  bool _bool(YamlMap map, String key, String where, {required bool fallback}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is bool) return value;
    throw _error(node, '$where must be true or false.');
  }

  int _int(YamlMap map, String key, String where, {required int fallback}) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is int && value >= 1) return value;
    throw _error(node, '$where must be a whole number of at least 1.');
  }

  String _string(
    YamlMap map,
    String key,
    String where, {
    required String fallback,
    List<String>? oneOf,
  }) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    final value = node.value;
    if (value is String && (oneOf == null || oneOf.contains(value))) {
      return value;
    }
    throw _error(
      node,
      oneOf == null
          ? '$where must be text.'
          : '$where must be one of: ${oneOf.join(', ')}.',
    );
  }

  List<String> _stringList(
    YamlMap map,
    String key,
    String where, {
    required List<String> fallback,
    List<String>? oneOf,
    RegExp? pattern,
    bool nonEmpty = false,
  }) {
    final node = map.nodes[key];
    if (node == null || _isNull(node)) return fallback;
    if (node is! YamlList) {
      throw _error(node, '$where must be a list, like [a, b].');
    }
    final result = <String>[];
    for (final item in node.nodes) {
      final value = item.value;
      if (value is! String) {
        throw _error(item, 'Every entry in $where must be text.');
      }
      if (oneOf != null && !oneOf.contains(value)) {
        throw _error(
          item,
          '"$value" is not allowed in $where. '
          'Allowed: ${oneOf.join(', ')}.',
        );
      }
      if (pattern != null && !pattern.hasMatch(value)) {
        throw _error(item, '"$value" in $where is not a valid package name.');
      }
      if (result.contains(value)) {
        throw _error(item, '"$value" appears twice in $where.');
      }
      result.add(value);
    }
    if (nonEmpty && result.isEmpty) {
      throw _error(node, '$where needs at least one entry.');
    }
    return List.unmodifiable(result);
  }
}
