import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:path/path.dart' as p;

import 'layer_config.dart';

/// Enforces the layer boundaries declared in `appstein_lints:`
/// (spec §9.6). An import or export that crosses a forbidden boundary is
/// reported at its URI.
final class LayerImportsRule extends MultiAnalysisRule {
  /// Creates the rule.
  LayerImportsRule()
    : super(
        name: 'layer_imports',
        description:
            'Code in one layer may only import the layers it is '
            'allowed to.',
      );

  /// Reported at an import or export that crosses a forbidden boundary.
  static const LintCode forbiddenImport = LintCode(
    'layer_imports',
    "The '{0}' layer can't import '{2}', which is in the '{1}' layer.",
    correctionMessage:
        "The '{0}' layer may import: {3}. Import an allowed "
        'layer instead, or move the code.',
    uniqueName: 'layer_imports_forbidden',
  );

  /// Reported once per file when the `appstein_lints:` section is invalid.
  static const LintCode invalidConfig = LintCode(
    'layer_imports',
    'The appstein_lints layer rules in {0} are invalid: {1}',
    correctionMessage: 'Fix the appstein_lints section of that file.',
    uniqueName: 'layer_imports_invalid_config',
  );

  final _finder = LayerConfigFinder();

  @override
  List<DiagnosticCode> get diagnosticCodes => [forbiddenImport, invalidConfig];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final file = (context.currentUnit ?? context.definingUnit).file;
    final config = _finder.find(file);
    if (config == null) return;
    final visitor = _Visitor(this, config, file);
    registry
      ..addCompilationUnit(this, visitor)
      ..addImportDirective(this, visitor)
      ..addExportDirective(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.config, this.file)
    : _paths = file.provider.pathContext;

  final LayerImportsRule rule;
  final LayerConfig config;
  final File file;
  final p.Context _paths;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final error = config.error;
    if (error != null) {
      rule.reportAtOffset(
        0,
        0,
        diagnosticCode: LayerImportsRule.invalidConfig,
        arguments: [config.optionsPath, error],
      );
    }
  }

  @override
  void visitImportDirective(ImportDirective node) =>
      _check(node, node.libraryImport?.importedLibrary);

  @override
  void visitExportDirective(ExportDirective node) =>
      _check(node, node.libraryExport?.exportedLibrary);

  void _check(NamespaceDirective node, LibraryElement? target) {
    final matcher = config.matcher;
    final rules = config.rules;
    if (matcher == null || rules == null || target == null) return;
    final fromPath = _relative(file.path);
    final toPath = _relative(target.firstFragment.source.fullName);
    if (fromPath == null || toPath == null) return;
    final fromTag = matcher.tagFor(fromPath);
    final toTag = matcher.tagFor(toPath);
    if (fromTag == null || toTag == null || rules.mayImport(fromTag, toTag)) {
      return;
    }
    final allowed = [fromTag, ...?rules.allow[fromTag]].join(', ');
    rule.reportAtNode(
      node.uri,
      diagnosticCode: LayerImportsRule.forbiddenImport,
      arguments: [fromTag, toTag, toPath, allowed],
    );
  }

  /// [path] relative to the config folder, with `/` separators. Null when
  /// it is outside that folder (the SDK or the pub cache).
  String? _relative(String path) {
    if (!_paths.isWithin(config.rootPath, path)) return null;
    return _paths.split(_paths.relative(path, from: config.rootPath)).join('/');
  }
}
