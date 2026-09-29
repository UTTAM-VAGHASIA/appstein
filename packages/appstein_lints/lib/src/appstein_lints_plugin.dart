import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'layer_imports/layer_imports_rule.dart';

/// Registers Appstein's lint rules with the Dart analysis server.
///
/// Plugin lint rules are off by default. A project turns them on under
/// `plugins: appstein_lints: diagnostics:` in `analysis_options.yaml`.
final class AppsteinLintsPlugin extends Plugin {
  @override
  String get name => 'appstein_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerLintRule(LayerImportsRule());
  }
}
