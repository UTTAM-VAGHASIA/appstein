import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('defaults match spec §7', () {
    expect(const AppsteinConfig().toJson(), {
      'appstein': 1,
      'packs': {
        'stack': 'official_mvvm',
        'platforms': ['android', 'ios'],
      },
      'delta': {'baseline': '3.16'},
      'verify': {
        'fast_timeout_seconds': 20,
        'build_on_full': true,
        'severity': <String, String>{},
      },
      'docs': {'enabled': true, 'path': 'docs/app'},
      'packages': {
        'stale_after_months': 12,
        'allow': <String>[],
        'deny': <String>[],
      },
      'integrations': {
        'agents': ['claude', 'codex'],
        'graphify_export': false,
        'developer_knowledge_mcp': false,
      },
    });
  });
}
