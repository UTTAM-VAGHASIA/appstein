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

  test(
    'without FVM_CACHE_PATH, the cache is fvm/versions in the home folder',
    () {
      pin('3.47.5');
      final home = p.join(work.path, 'home');
      createFakeSdk(p.join(home, 'fvm', 'versions', '3.47.5'));
      final env = fakeEnvironment({
        Platform.isWindows ? 'USERPROFILE' : 'HOME': home,
      });
      final lookup = FlutterSdkLocator(env).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
    },
  );

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

  test('a pin that is not installed falls back to FLUTTER_ROOT', () {
    pin('3.47.5');
    final sdk = createFakeSdk(p.join(work.path, 'flutter root'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({
        'FVM_CACHE_PATH': p.join(work.path, 'empty'),
        'FLUTTER_ROOT': sdk,
      }),
    ).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.flutterRoot);
    expect(lookup.location!.unmetFvmPin, '3.47.5');
    expect(lookup.location!.fvmVersion, isNull);
  });

  test('a pin that FVM has installed leaves unmetFvmPin null', () {
    pin('3.47.5');
    final cache = p.join(work.path, 'fvm cache');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({'FVM_CACHE_PATH': cache}),
    ).locate(projectRoot: project);
    expect(lookup.location!.unmetFvmPin, isNull);
  });

  group('a pin in a parent folder', () {
    test('is found, and its link is resolved next to the pin', () {
      // The pin and its link live in `work`; the project is `work/my app`.
      File(
        p.join(work.path, '.fvmrc'),
      ).writeAsStringSync('{"flutter": "3.47.5"}');
      final real = createFakeSdk(p.join(work.path, 'real sdk'));
      Link(
        p.join(work.path, '.fvm', 'flutter_sdk'),
      ).createSync(real, recursive: true);
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
      expect(lookup.location!.fvmVersion, '3.47.5');
      expect(p.equals(lookup.location!.root, resolveLinks(real)), isTrue);
    });

    test('the nearest pin wins over one further up', () {
      File(
        p.join(work.path, '.fvmrc'),
      ).writeAsStringSync('{"flutter": "3.44.0"}');
      pin('3.47.5');
      final cache = p.join(work.path, 'fvm cache');
      createFakeSdk(p.join(cache, 'versions', '3.47.5'));
      createFakeSdk(p.join(cache, 'versions', '3.44.0'), flutter: '3.44.0');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': cache}),
      ).locate(projectRoot: project);
      expect(lookup.location!.fvmVersion, '3.47.5');
    });
  });

  group('a stale .fvm/flutter_sdk link', () {
    late String cache;

    setUp(() {
      cache = p.join(work.path, 'fvm cache');
      final old = createFakeSdk(p.join(work.path, 'old'), flutter: '3.46.0');
      Link(
        p.join(project, '.fvm', 'flutter_sdk'),
      ).createSync(old, recursive: true);
    });

    SdkLookup locate({Map<String, String> extra = const {}}) =>
        FlutterSdkLocator(
          fakeEnvironment({'FVM_CACHE_PATH': cache, ...extra}),
        ).locate(projectRoot: project);

    test('is skipped for the cache SDK of the pinned version', () {
      pin('3.47.5');
      createFakeSdk(p.join(cache, 'versions', '3.47.5'));
      final location = locate().location!;
      expect(location.source, SdkSource.fvm);
      expect(
        p.equals(location.root, p.join(cache, 'versions', '3.47.5')),
        isTrue,
      );
    });

    test('with no cache SDK, the pin counts as not installed', () {
      pin('3.47.5');
      final lookup = locate();
      expect(lookup.location, isNull);
      expect(lookup.fixHint, contains('fvm install 3.47.5'));
    });

    test('with no cache SDK, FLUTTER_ROOT can still meet the pin', () {
      pin('3.47.5');
      final sdk = createFakeSdk(p.join(work.path, 'flutter root'));
      final location = locate(extra: {'FLUTTER_ROOT': sdk}).location!;
      expect(location.source, SdkSource.flutterRoot);
      expect(location.unmetFvmPin, '3.47.5');
    });

    test('is still used when the pin is a channel name', () {
      pin('stable');
      final location = locate().location!;
      expect(location.source, SdkSource.fvm);
      expect(location.fvmVersion, 'stable');
    });

    test('is still used when its SDK was never set up', () {
      Link(p.join(project, '.fvm', 'flutter_sdk')).deleteSync();
      final fresh = createFakeSdk(p.join(work.path, 'fresh'), setUp: false);
      Link(p.join(project, '.fvm', 'flutter_sdk')).createSync(fresh);
      pin('3.47.5');
      final location = locate().location!;
      expect(location.source, SdkSource.fvm);
      expect(p.equals(location.root, resolveLinks(fresh)), isTrue);
    });
  });

  test('a flutter on PATH that is not inside an SDK says so', () {
    final tools = Directory(p.join(work.path, 'shims'))..createSync();
    final shim = fakeExecutable(tools, 'flutter');
    final lookup = FlutterSdkLocator(
      fakeEnvironment({'PATH': tools.path, 'PATHEXT': defaultPathExt}),
    ).locate(projectRoot: project);
    expect(lookup.location, isNull);
    expect(lookup.problem, contains('is not inside a Flutter SDK folder'));
    expect(lookup.problem, contains(shim));
    expect(lookup.problem, isNot(contains('is not on PATH')));
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
