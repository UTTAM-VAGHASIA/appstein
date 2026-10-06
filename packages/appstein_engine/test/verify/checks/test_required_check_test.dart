import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../knowledge/support/sync_harness.dart';
import '../../support/fixture_app.dart';
import '../support/verify_support.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];
const _check = TestRequiredCheck();

void main() {
  test('it is `verify.test_required`, in full mode, and reads the map', () {
    expect(_check.ids, ['verify.test_required']);
    expect(_check.mode, VerifyMode.full);
    expect(_check.needsMap, isTrue);
  });

  test('each feature without a test is a warning on its folder, until it '
      'has one', () async {
    final sdk = fakeFlutter();
    final app = copyFixtureApp();
    Future<List<Finding>> run() async =>
        _check.run(await contextFor(app, flutterRoot: sdk, packs: _packs));

    // The fixture has tests for `booking` and `home` only.
    final findings = await run();
    expect(
      [for (final finding in findings) (finding.file, finding.message)],
      [
        ('lib/ui/auth/login', 'The feature `auth/login` has no test.'),
        ('lib/ui/profile', 'The feature `profile` has no test.'),
        ('lib/ui/settings', 'The feature `settings` has no test.'),
      ],
    );
    for (final finding in findings) {
      expect(finding.id, 'verify.test_required');
      expect(finding.severity, Severity.warning);
      expect(finding.line, isNull);
      expect(finding.knowledgeRef, '.appstein/map/features.json');
    }
    expect(findings.first.fixHint, 'Add a test under `test/ui/auth/login/`.');

    File(p.join(app, 'test', 'ui', 'profile', 'profile_test.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    expect(
      [for (final finding in await run()) finding.file],
      ['lib/ui/auth/login', 'lib/ui/settings'],
    );
  });
}
