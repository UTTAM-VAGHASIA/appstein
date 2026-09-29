import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  late Directory work;
  late String project;

  setUp(() {
    work = tempDir();
    project = Directory(p.join(work.path, 'my app')).path;
    Directory(project).createSync();
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: my_app');
  });

  void pin(String version) => File(
    p.join(project, '.fvmrc'),
  ).writeAsStringSync('{"flutter": "$version"}');

  test('uses the FVM cache for the pinned version', () {
    pin('3.47.5');
    final cache = p.join(work.path, 'fvm cache');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final env = fakeEnvironment({'FVM_CACHE_PATH': cache});
    final lookup = FlutterSdkLocator(env).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.fvm);
    expect(lookup.location!.fvmVersion, '3.47.5');
  });

  test('prefers the project .fvm/flutter_sdk link when it is valid', () {
    pin('3.47.5');
    final real = createFakeSdk(p.join(work.path, 'real sdk'));
    Link(
      p.join(project, '.fvm', 'flutter_sdk'),
    ).createSync(real, recursive: true);
    final lookup = FlutterSdkLocator(
      fakeEnvironment({}),
    ).locate(projectRoot: project);
    expect(p.equals(lookup.location!.root, resolveLinks(real)), isTrue);
  });

  // Review Focus 5: after `fvm remove`, the link can dangle.
  test('a dangling link falls back to the FVM cache', () {
    pin('3.47.5');
    final gone = Directory(p.join(work.path, 'removed sdk'))..createSync();
    Link(
      p.join(project, '.fvm', 'flutter_sdk'),
    ).createSync(gone.path, recursive: true);
    gone.deleteSync();
    final cache = p.join(work.path, 'fvm cache');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({'FVM_CACHE_PATH': cache}),
    ).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.fvm);
  });

  test('a pinned version that is not installed says how to install it', () {
    pin('3.46.0');
    final lookup = FlutterSdkLocator(
      fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
    ).locate(projectRoot: project);
    expect(lookup.location, isNull);
    expect(lookup.fixHint, contains('fvm install 3.46.0'));
  });

  test('without FVM, uses FLUTTER_ROOT', () {
    final sdk = createFakeSdk(p.join(work.path, 'flutter root'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({'FLUTTER_ROOT': sdk}),
    ).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.flutterRoot);
  });

  test('without FVM or FLUTTER_ROOT, uses flutter on PATH', () {
    final sdk = createFakeSdk(p.join(work.path, 'päth sdk'));
    final env = fakeEnvironment({
      'PATH': p.join(sdk, 'bin'),
      'PATHEXT': defaultPathExt,
    });
    final lookup = FlutterSdkLocator(env).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.path);
    expect(p.equals(lookup.location!.root, resolveLinks(sdk)), isTrue);
  });

  test('with nothing installed, explains what to do', () {
    final lookup = FlutterSdkLocator(
      fakeEnvironment({}),
    ).locate(projectRoot: project);
    expect(lookup.problem, contains('No Flutter SDK found'));
  });
}
