// The reflective test loader finds tests by their `test_` name prefix.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer_testing/utilities/utilities.dart';
import 'package:appstein_lints/src/layer_imports/layer_imports_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(LayerImportsRuleTest);
  });
}

@reflectiveTest
class LayerImportsRuleTest extends AnalysisRuleTest {
  static const _layers = '''
appstein_lints:
  layers:
    ui: [lib/ui/**]
    domain: [lib/domain/**]
    data: [lib/data/**]
  allow:
    ui: [domain]
    domain: []
''';

  String get _ui => '$testPackageLibPath/ui/home.dart';

  void _options(String appsteinSection) => newAnalysisOptionsYamlFile(
    testPackageRootPath,
    '${analysisOptionsContent(rules: ['layer_imports'])}\n$appsteinSection',
  );

  @override
  void setUp() {
    rule = LayerImportsRule();
    super.setUp();
    _options(_layers);
    newFile('$testPackageLibPath/domain/user.dart', 'class User {}');
    newFile('$testPackageLibPath/data/repo.dart', 'class Repo {}');
  }

  Future<void> test_allowedImport() async {
    newFile(_ui, "import '../domain/user.dart';\nUser? u;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_forbiddenRelativeImport() async {
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [
      lint(
        7,
        19,
        messageContainsAll: ["'ui' layer can't import", 'lib/data/repo.dart'],
      ),
    ]);
  }

  Future<void> test_forbiddenPackageImport() async {
    newFile(_ui, "import 'package:test/data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 29)]);
  }

  Future<void> test_exportIsChecked() async {
    newFile(_ui, "export '../data/repo.dart';\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 19)]);
  }

  Future<void> test_sameLayerIsAllowed() async {
    newFile('$testPackageLibPath/ui/widgets.dart', 'class W {}');
    newFile(_ui, "import 'widgets.dart';\nW? w;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_layerWithoutAllowEntryIsUnrestricted() async {
    final data = '$testPackageLibPath/data/uses_ui.dart';
    newFile('$testPackageLibPath/ui/widgets.dart', 'class W {}');
    newFile(data, "import '../ui/widgets.dart';\nW? w;\n");
    await assertNoDiagnosticsInFile(data);
  }

  Future<void> test_untaggedFileIsIgnored() async {
    final main = '$testPackageLibPath/main.dart';
    newFile(main, "import 'data/repo.dart';\nRepo? r;\n");
    await assertNoDiagnosticsInFile(main);
  }

  Future<void> test_noAppsteinSectionMeansNoRule() async {
    _options('');
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  static const _workspaceLayers = '''
appstein_lints:
  layers:
    ui: [test/lib/ui/**]
    data: [test/lib/data/**]
  allow:
    ui: []
''';

  Future<void> test_workspaceParentConfigIsFound() async {
    newAnalysisOptionsYamlFile('/home', _workspaceLayers);
    _options('');
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 19)]);
  }

  Future<void> test_editedConfigInvalidatesTheCache() async {
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 19)]);
    // newFile refuses non-Dart changes after analysis, so edit in place.
    // The analysis context keeps its cached options, so this only changes
    // what the rule's own finder reads. Touching the Dart file re-runs it.
    getFile('$testPackageRootPath/analysis_options.yaml').writeAsStringSync(
      '${analysisOptionsContent(rules: ['layer_imports'])}\n'
      '${_layers.replaceFirst('ui: [domain]', 'ui: [data]')}',
    );
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n// edited\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_invalidConfigIsReported() async {
    _options(
      'appstein_lints:\n  layers:\n    ui: [lib/ui/**]\n'
      '  allow:\n    ui: [nowhere]\n',
    );
    newFile(_ui, 'class A {}\n');
    await assertDiagnosticsInFile(_ui, [
      lint(0, 0, messageContainsAll: ['invalid', '"nowhere"']),
    ]);
  }

  Future<void> test_invalidGlobIsReportedNotThrown() async {
    _options(
      'appstein_lints:\n  layers:\n    ui: ["lib/[ui/**"]\n'
      '  allow:\n    ui: []\n',
    );
    newFile(_ui, 'class A {}\n');
    await assertDiagnosticsInFile(_ui, [
      lint(0, 0, messageContainsAll: ['invalid']),
    ]);
  }
}
