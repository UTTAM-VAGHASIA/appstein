import 'dart:convert';
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

    // Review Focus 4.
    test('a version@channel pin compares its version and has its own cache '
        'folder', () {
      pin('3.24.0@beta');
      final sdk = createFakeSdk(
        p.join(cache, 'versions', '3.24.0@beta'),
        flutter: '3.24.0',
        channel: 'beta',
      );
      final location = locate().location!;
      expect(p.equals(location.root, sdk), isTrue);
      expect(location.fvmVersion, '3.24.0@beta');
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

  group("FVM's cache folder", () {
    test("the pin file's cachePath comes first, relative to the pin's "
        'folder', () {
      File(p.join(project, '.fvmrc')).writeAsStringSync(
        jsonEncode({'flutter': '3.47.5', 'cachePath': 'my cache'}),
      );
      final sdk = createFakeSdk(
        p.join(project, 'my cache', 'versions', '3.47.5'),
      );
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(p.equals(lookup.location!.root, sdk), isTrue);
    });

    test('FVM_HOME is used when FVM_CACHE_PATH is not set', () {
      pin('3.47.5');
      final fvmHome = p.join(work.path, 'fvm home');
      createFakeSdk(p.join(fvmHome, 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_HOME': fvmHome}),
      ).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
    });

    test("FVM's global settings give the cache when nothing else does", () {
      pin('3.47.5');
      final home = p.join(work.path, 'home');
      final cache = p.join(work.path, 'global cache');
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'cachePath': cache}));
      final sdk = createFakeSdk(p.join(cache, 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment(fvmHomeVars(home)),
      ).locate(projectRoot: project);
      expect(p.equals(lookup.location!.root, sdk), isTrue);
    });

    // Review Focus 3.
    test('a global settings file that is not JSON is ignored', () {
      pin('3.47.5');
      final home = p.join(work.path, 'home');
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      createFakeSdk(p.join(home, 'fvm', 'versions', '3.47.5'));
      final lookup = FlutterSdkLocator(
        fakeEnvironment(fvmHomeVars(home)),
      ).locate(projectRoot: project);
      expect(lookup.location!.source, SdkSource.fvm);
    });
  });

  test('a FLUTTER_ROOT that is not an SDK is skipped, with a note', () {
    final bad = p.join(work.path, 'not an sdk');
    final sdk = createFakeSdk(p.join(work.path, 'päth sdk'));
    final lookup = FlutterSdkLocator(
      fakeEnvironment({
        'FLUTTER_ROOT': bad,
        'PATH': p.join(sdk, 'bin'),
        'PATHEXT': defaultPathExt,
      }),
    ).locate(projectRoot: project);
    expect(lookup.location!.source, SdkSource.path);
    expect(lookup.location!.notes, [
      'FLUTTER_ROOT is set to $bad, which is not a Flutter SDK, so it was '
          'ignored.',
    ]);
  });

  group('when no SDK is found, the problem names what was tried', () {
    const installHint =
        'Install Flutter (https://docs.flutter.dev/get-started/install), or '
        'pin a version in the project with `fvm use <version>`.';

    test('in a project without a pin', () {
      final lookup = FlutterSdkLocator(
        fakeEnvironment({}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        'No Flutter SDK found. Tried: no FVM pin in the project, '
        'FLUTTER_ROOT (not set), `flutter` on PATH (not found).',
      );
      expect(lookup.fixHint, installHint);
    });

    test('outside a project, without the FVM part', () {
      expect(
        FlutterSdkLocator(fakeEnvironment({})).locate().problem,
        'No Flutter SDK found. Tried: FLUTTER_ROOT (not set), `flutter` on '
        'PATH (not found).',
      );
    });

    test('with a pin FVM does not have', () {
      pin('3.46.0');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        "No Flutter SDK found. Tried: the project's FVM pin (Flutter 3.46.0, "
        'from ${p.join(project, '.fvmrc')}, not installed), FLUTTER_ROOT '
        '(not set), `flutter` on PATH (not found).',
      );
      expect(lookup.fixHint, 'Run `fvm install 3.46.0` in the project folder.');
    });

    test('with a channel pin FVM does not have', () {
      pin('stable');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({'FVM_CACHE_PATH': p.join(work.path, 'empty')}),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        contains("the project's FVM pin (the Flutter stable channel, from "),
      );
      expect(
        lookup.fixHint,
        'Run `fvm install stable` or `fvm use stable` in the project folder.',
      );
    });

    test('with a FLUTTER_ROOT that is not an SDK, and a flutter on PATH '
        'outside one', () {
      final bad = p.join(work.path, 'not an sdk');
      final tools = Directory(p.join(work.path, 'shims'))..createSync();
      final shim = fakeExecutable(tools, 'flutter');
      final lookup = FlutterSdkLocator(
        fakeEnvironment({
          'FLUTTER_ROOT': bad,
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ).locate(projectRoot: project);
      expect(
        lookup.problem,
        'No Flutter SDK found. Tried: no FVM pin in the project, '
        'FLUTTER_ROOT (set to $bad, not an SDK), `flutter` on PATH (found at '
        '$shim, not inside an SDK).',
      );
    });
  });
}
