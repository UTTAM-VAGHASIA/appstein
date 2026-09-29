import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:appstein_lints/src/layer_imports/layer_config.dart';
import 'package:test/test.dart';

void main() {
  late MemoryResourceProvider provider;
  late LayerConfigFinder finder;

  const section = 'appstein_lints:\n  layers:\n    ui: [lib/**]\n';

  setUp(() {
    provider = MemoryResourceProvider();
    finder = LayerConfigFinder();
  });

  // The suggested replacement extension is not part of analyzer 14.4.0's
  // public API.
  // ignore: deprecated_member_use
  String path(String posix) => provider.convertPath(posix);

  test('walks up past an options file with no appstein_lints section', () {
    provider.newFile(path('/ws/analysis_options.yaml'), section);
    provider.newFile(path('/ws/pkg/analysis_options.yaml'), 'include: x\n');
    final file = provider.newFile(path('/ws/pkg/lib/a.dart'), '');

    final config = finder.find(file);

    expect(config?.optionsPath, path('/ws/analysis_options.yaml'));
    expect(config?.rules, isNotNull);
  });

  test('a broken nearer options file stops the walk and applies no rules', () {
    provider.newFile(path('/ws/analysis_options.yaml'), section);
    provider.newFile(path('/ws/pkg/analysis_options.yaml'), 'foo: [unclosed\n');
    final file = provider.newFile(path('/ws/pkg/lib/a.dart'), '');

    expect(finder.find(file), isNull);
  });

  test('an edited options file is read again', () {
    final options = provider.newFile(
      path('/ws/analysis_options.yaml'),
      section,
    );
    final file = provider.newFile(path('/ws/lib/a.dart'), '');
    expect(finder.find(file)?.rules?.layers.keys, ['ui']);

    options.writeAsStringSync(
      'appstein_lints:\n  layers:\n    data: [lib/**]\n',
    );

    expect(finder.find(file)?.rules?.layers.keys, ['data']);
  });
}
