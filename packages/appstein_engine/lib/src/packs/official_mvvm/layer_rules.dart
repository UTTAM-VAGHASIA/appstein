import 'package:appstein_protocol/appstein_protocol.dart';

/// official_mvvm's layer tags (spec §6.5) and rules (§9.6), matching
/// Flutter's architecture guide and its compass_app sample:
/// - ui may import domain, routing, config and utils, plus the interfaces
///   of repositories and services;
/// - domain may import utils, plus the interfaces of repositories (use
///   cases call repositories);
/// - data.* may import anything but ui;
/// - routing, config, utils and tests are unrestricted.
///
/// Tests come first, so a file under `test/` is never tagged by a `lib/`
/// glob.
const officialMvvmLayerRules = LayerRules(
  layers: {
    'test': ['test/**', 'testing/**'],
    'ui': ['lib/ui/**'],
    'data.repository': ['lib/data/repositories/**'],
    'data.service': ['lib/data/services/**'],
    'data.model': ['lib/data/model/**'],
    'domain': ['lib/domain/**'],
    'routing': ['lib/routing/**'],
    'config': ['lib/config/**'],
    'utils': ['lib/utils/**'],
  },
  allow: {
    'ui': ['domain', 'routing', 'config', 'utils'],
    'domain': ['utils'],
    'data.repository': [
      'test',
      'data.service',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ],
    'data.service': [
      'test',
      'data.repository',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ],
    'data.model': [
      'test',
      'data.repository',
      'data.service',
      'domain',
      'routing',
      'config',
      'utils',
    ],
  },
  interfaces: {
    'ui': ['data.repository', 'data.service'],
    'domain': ['data.repository'],
  },
);
