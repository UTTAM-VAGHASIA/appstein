import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/temp.dart';

final class _Extractor implements NativeExtractor {
  _Extractor(this.section, this.result);

  @override
  final String section;

  final NativeSection Function(NativeContext context) result;

  @override
  NativeSection extract(NativeContext context) => result(context);
}

final class _Pack implements Pack {
  _Pack(this.id, this.nativeExtractor);

  @override
  final String id;

  @override
  final NativeExtractor? nativeExtractor;

  @override
  PackKind get kind => PackKind.platform;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  LayerRules? get layerRules => null;
}

void main() {
  NativeContext context({String flutter = '3.47.5'}) => NativeContext(
    projectRoot: tempDir().path,
    flutterVersion: flutter,
    channel: 'stable',
    environment: fakeEnvironment({}),
  );

  Pack pack(String section, NativeSection Function(NativeContext) result) =>
      _Pack(section, _Extractor(section, result));

  NativeSync sync(List<Pack> packs) =>
      NativeSync(appsteinVersion: '0.1.0-dev', packs: packs);

  test('with no native extractor there is no file', () {
    final build = sync([_Pack('official_mvvm', null)]).build(context());
    expect(build.file, isNull);
    expect(build.report.sections, isEmpty);
  });

  test('each pack writes its own section of map/native.json', () {
    final build = sync([
      pack(
        'android',
        (_) => NativeSection(
          NativeGroup({'gradle': const NativeValue.found('9.3.1')}),
          {'file:android/gradle.properties': utf8.encode('a=1')},
        ),
      ),
      pack(
        'ios',
        (_) => const NativeSection(NativeValue.absent('no ios/ folder'), {}),
      ),
    ]).build(context());
    expect(build.file!.path, MapFiles.native);
    expect(build.file!.body, {
      'android': {
        'gradle': {'status': 'found', 'value': '9.3.1'},
      },
      'ios': {'status': 'absent', 'reason': 'no ios/ folder'},
    });
    expect(build.report.sections, {
      'android': 'read',
      'ios': 'absent: no ios/ folder',
    });
    expect(build.report.errors, isEmpty);
  });

  test('a pack that throws costs only its own section', () {
    final build = sync([
      pack('android', (_) => throw StateError('broken at C:\\Users\\me')),
      pack(
        'ios',
        (_) => const NativeSection(NativeValue.absent('no ios/ folder'), {}),
      ),
    ]).build(context());
    expect(build.file!.body!['android'], {
      'status': 'error',
      'errorType': 'StateError',
    });
    expect(build.file!.body!['ios'], isNotNull);
    expect(build.report.sections['android'], 'internal error (StateError)');
    expect(build.report.errors['android'], contains('broken at'));
    expect(jsonEncode(build.file!.body), isNot(contains('Users')));
  });

  test('two packs writing one section is a StateError', () {
    NativeSection empty(NativeContext _) =>
        const NativeSection(NativeValue.absent('x'), {});
    expect(
      () => sync([
        pack('android', empty),
        pack('android', empty),
      ]).build(context()),
      throwsStateError,
    );
  });

  test('the hash follows the inputs and the Flutter version', () {
    String hash(List<int>? bytes, {String flutter = '3.47.5'}) => sync([
      pack(
        'android',
        (_) => NativeSection(const NativeValue.found(1), {'file:x': bytes}),
      ),
    ]).build(context(flutter: flutter)).file!.inputHash;

    expect(hash([1]), hash([1]));
    expect(hash([1]), isNot(hash([2])));
    expect(hash([1]), isNot(hash(null)));
    expect(hash([1]), isNot(hash([1], flutter: '3.44.9')));
  });
}
