import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

const _full = Finding(
  id: 'android.kgp_applied_by_plugin',
  severity: Severity.error,
  file: 'android/app/build.gradle.kts',
  line: 3,
  message: "Plugin 'foo_plugin 1.2.0' applies the Kotlin Gradle Plugin.",
  fixHint: 'Upgrade foo_plugin to >= 1.3.0.',
  knowledgeRef: '.appstein/platform/toolchain.json#kotlin',
  pack: 'android',
  docs: 'https://docs.flutter.dev/x',
);

const _small = Finding(
  id: 'knowledge.stale',
  severity: Severity.warning,
  message: 'm',
);

void main() {
  test('the JSON form has the keys of spec §9.3, in its order', () {
    expect(_full.toJson().keys, [
      'id',
      'severity',
      'file',
      'line',
      'message',
      'fixHint',
      'knowledgeRef',
      'pack',
      'docs',
    ]);
    expect(_full.toJson(), {
      'id': 'android.kgp_applied_by_plugin',
      'severity': 'error',
      'file': 'android/app/build.gradle.kts',
      'line': 3,
      'message': "Plugin 'foo_plugin 1.2.0' applies the Kotlin Gradle Plugin.",
      'fixHint': 'Upgrade foo_plugin to >= 1.3.0.',
      'knowledgeRef': '.appstein/platform/toolchain.json#kotlin',
      'pack': 'android',
      'docs': 'https://docs.flutter.dev/x',
    });
  });

  test('fields that are not set are left out', () {
    expect(_small.toJson(), {
      'id': 'knowledge.stale',
      'severity': 'warning',
      'message': 'm',
    });
  });

  test('reads its own JSON form back', () {
    for (final finding in [_full, _small]) {
      expect(Finding.fromJson(finding.toJson()).toJson(), finding.toJson());
    }
  });

  Matcher formatError(String part) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', contains(part)),
  );

  test('refuses a damaged finding, naming the field', () {
    expect(
      () => Finding.fromJson({'severity': 'error', 'message': 'm'}),
      formatError('"id"'),
    );
    expect(
      () => Finding.fromJson({'id': 'a.b', 'severity': 'bad', 'message': 'm'}),
      formatError('"severity"'),
    );
    expect(
      () => Finding.fromJson({
        'id': 'a.b',
        'severity': 'error',
        'message': 'm',
        'line': '3',
      }),
      formatError('"line"'),
    );
  });

  test('withSeverity and withPack change only that field', () {
    final raised = _small.withSeverity(Severity.error);
    expect(raised.toJson(), {..._small.toJson(), 'severity': 'error'});
    final stamped = _full.withPack('ios');
    expect(stamped.toJson(), {..._full.toJson(), 'pack': 'ios'});
  });
}
