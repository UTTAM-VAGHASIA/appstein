import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify_check.dart';

/// `verify.test_required` (spec §9.2): every feature of the project map has
/// at least one test.
///
/// It reads `map/features.json`, which the stack pack writes, so what a
/// feature is and where its tests live stay the pack's knowledge.
final class TestRequiredCheck implements VerifyCheck {
  /// Creates the check.
  const TestRequiredCheck();

  @override
  List<String> get ids => const ['verify.test_required'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => true;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final features = context.knowledge.features.value?.features;
    if (features == null) return const [];
    return [
      for (final name in features.keys.toList()..sort())
        if (features[name]!.tests.isEmpty)
          Finding(
            id: ids.first,
            severity: Severity.warning,
            file: features[name]!.folder,
            message: 'The feature `$name` has no test.',
            fixHint: 'Add a test under `${_testFolder(features[name]!)}/`.',
            knowledgeRef: '.appstein/${MapFiles.features}',
          ),
    ];
  }
}

/// Where [feature]'s tests go: its folder, under `test/` instead of `lib/`.
/// The map counts the tests it finds there.
String _testFolder(Feature feature) => feature.folder.startsWith('lib/')
    ? 'test/${feature.folder.substring(4)}'
    : 'test';
