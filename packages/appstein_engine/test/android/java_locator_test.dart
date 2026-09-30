import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_android.dart';
import '../support/fake_process_runner.dart';
import '../support/temp.dart';

void main() {
  late FakeProcessRunner runner;

  setUp(() => runner = FakeProcessRunner());

  String javaIn(String home, [HostOs? os]) => p.join(
    home,
    'bin',
    (os ?? HostOs.current) == HostOs.windows ? 'java.exe' : 'java',
  );

  const java21 = RunResult(
    exitCode: 0,
    stderr: 'openjdk version "21.0.6" 2025-01-21',
  );
  const brokenJava = RunResult(
    exitCode: 1,
    stderr: "Error: could not open `jvm.cfg'",
  );

  /// An Android Studio folder whose bundled JDK runs.
  String workingStudio(Directory parent, [String name = 'Android Studio']) {
    final studio = fakeStudio(parent, name: name);
    runner.when(javaIn(studioJdkHome(studio)), ['-version'], java21);
    return studio;
  }

  /// An Android Studio folder whose bundled JDK exits with an error.
  String brokenStudio(Directory parent, [String name = 'Broken Studio']) {
    final studio = fakeStudio(parent, name: name);
    runner.when(javaIn(studioJdkHome(studio)), ['-version'], brokenJava);
    return studio;
  }

  String skippedNote(String studio) =>
      'Android Studio at $studio has a JDK that does not run; '
      'Flutter skips it.';

  /// Variables that make [home] the user's home folder.
  Map<String, String> homeVars(String home) =>
      Platform.isWindows ? {'USERPROFILE': home} : {'HOME': home};

  /// The JDK location alone, for tests that don't look at skipped installs.
  Future<JavaLocation?> locate(
    HostEnvironment environment,
    Map<String, Object?> settings,
  ) async => (await locateFlutterJava(environment, settings, runner)).location;

  test('flutter config --jdk-dir wins', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': 'configured',
    });
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, 'configured');
    expect(runner.calls, isEmpty);
  });

  test('an empty jdk-dir still counts, as in Flutter', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': '',
    });
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, '');
    expect(location.javaBinary, javaIn(''));
  });

  test('a jdk-dir of JSON null counts as unset', () async {
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': null,
    });
    expect(location!.source, JavaSource.javaHome);
  }, skip: studioInstalledReason());

  test("Android Studio's JDK comes before JAVA_HOME", () async {
    final studio = workingStudio(tempDir());
    final location = await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'android-studio-dir': studio,
    });
    expect(location!.source, JavaSource.androidStudio);
    expect(location.home, studioJdkHome(studio));
    expect(location.versionOutput, contains('21.0.6'));
  });

  test('then JAVA_HOME, then java on PATH', () async {
    expect(
      (await locate(fakeEnvironment({'JAVA_HOME': 'jh'}), {}))!.source,
      JavaSource.javaHome,
    );
    final bin = tempDir();
    fakeExecutable(bin, 'java');
    final onPath = await locate(
      fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
      {},
    );
    expect(onPath!.source, JavaSource.path);
  }, skip: studioInstalledReason());

  test('finds no JDK when there is none', () async {
    final lookup = await locateFlutterJava(fakeEnvironment({}), {}, runner);
    expect(lookup.location, isNull);
    expect(lookup.skipped, isEmpty);
  }, skip: studioInstalledReason());

  test('no JDK: the Studio passed over is still reported', () async {
    final studio = brokenStudio(tempDir());
    final lookup = await locateFlutterJava(fakeEnvironment({}), {
      'android-studio-dir': studio,
    }, runner);
    expect(lookup.location, isNull);
    expect(lookup.skipped, [skippedNote(studio)]);
  });

  test('parses the major version from java -version output', () {
    expect(parseJavaMajor('openjdk version "21.0.2" 2024-01-16'), 21);
    expect(parseJavaMajor('java version "1.8.0_202"'), 8);
    expect(parseJavaMajor('openjdk version "17" 2021-09-14'), 17);
    expect(parseJavaMajor('openjdk 21.0.1 2023-10-17'), 21);
    expect(parseJavaMajor('garbage'), isNull);
  });

  test(
    'Windows: finds Studio through the LOCALAPPDATA Google AndroidStudio .home',
    () async {
      final root = tempDir();
      final studio = workingStudio(root);
      final localAppData = p.join(root.path, 'local');
      final record = Directory(
        p.join(localAppData, 'Google', 'AndroidStudio2025.1'),
      )..createSync(recursive: true);
      File(p.join(record.path, '.home')).writeAsStringSync('$studio\r\n');
      final location = await locate(
        fakeEnvironment({'LOCALAPPDATA': localAppData}),
        {},
      );
      expect(location!.source, JavaSource.androidStudio);
      expect(location.home, studioJdkHome(studio));
    },
    testOn: 'windows',
  );

  test(
    'Linux: finds Studio through ~/.cache/Google/AndroidStudio*/.home',
    () async {
      final root = tempDir();
      final studio = workingStudio(root);
      final home = p.join(root.path, 'home');
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.1',
        studio,
      );
      final location = await locate(fakeEnvironment({'HOME': home}), {});
      expect(location!.source, JavaSource.androidStudio);
      expect(location.home, studioJdkHome(studio));
    },
    testOn: 'linux',
  );

  test('an unusable .home file is ignored', () async {
    final root = tempDir();
    final home = p.join(root.path, 'home');
    writeStudioRecord(
      p.join(home, '.cache', 'Google'),
      'AndroidStudio2025.1',
      'no such folder',
    );
    final location = await locate(
      fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
      {},
    );
    expect(location!.source, JavaSource.javaHome);
  }, skip: studioInstalledReason());

  group('choosing among Android Studio installs, as Flutter does', () {
    // The development machine on 2026-09-30: old and Preview records point to a
    // Studio whose JBR is broken; newer records point to a working one.
    // `flutter doctor -v` uses the working one.
    test(
      'regression: the newest Studio whose JDK runs, not the Preview record',
      () async {
        final root = tempDir();
        final broken = brokenStudio(root, 'Android Studio');
        final working = workingStudio(root, 'Android Studio1');
        final localAppData = p.join(root.path, 'local');
        final google = p.join(localAppData, 'Google');
        for (final folder in [
          'AndroidStudio2024.1',
          'AndroidStudio2024.2',
          'AndroidStudio2024.3',
          'AndroidStudioPreview2024.2',
        ]) {
          writeStudioRecord(google, folder, broken);
        }
        for (final folder in [
          'AndroidStudio2025.3.2',
          'AndroidStudio2025.3.4',
        ]) {
          writeStudioRecord(google, folder, working);
        }
        final location = await locate(
          fakeEnvironment({'LOCALAPPDATA': localAppData, 'JAVA_HOME': 'jh'}),
          {},
        );
        expect(location!.source, JavaSource.androidStudio);
        expect(location.home, studioJdkHome(working));
      },
      testOn: 'windows',
    );

    test(
      'a Studio whose java fails is skipped, even when it is the newest',
      () async {
        final root = tempDir();
        final home = p.join(root.path, 'home');
        final google = p.join(home, '.cache', 'Google');
        final broken = brokenStudio(root);
        final working = workingStudio(root);
        writeStudioRecord(google, 'AndroidStudio2025.3.4', broken);
        writeStudioRecord(google, 'AndroidStudio2024.3', working);
        final lookup = await locateFlutterJava(
          fakeEnvironment(homeVars(home)),
          {},
          runner,
        );
        expect(lookup.location!.home, studioJdkHome(working));
        expect(lookup.skipped, [skippedNote(broken)]);
      },
      testOn: '!mac-os',
      skip: studioInstalledReason(),
    );

    test(
      'JAVA_HOME is next when no Studio JDK runs',
      () async {
        final root = tempDir();
        final home = p.join(root.path, 'home');
        final broken = brokenStudio(root);
        writeStudioRecord(
          p.join(home, '.cache', 'Google'),
          'AndroidStudio2025.3.4',
          broken,
        );
        final lookup = await locateFlutterJava(
          fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
          {},
          runner,
        );
        expect(lookup.location!.source, JavaSource.javaHome);
        expect(lookup.skipped, [skippedNote(broken)]);
      },
      testOn: '!mac-os',
      skip: studioInstalledReason(),
    );

    test('newest version first; records are read in name order, so a release '
        'comes before its Preview', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final google = p.join(home, '.cache', 'Google');
      final records = {
        'AndroidStudio2024.3': workingStudio(root, 'Studio A'),
        'AndroidStudio2025.3.2': workingStudio(root, 'Studio B'),
        'AndroidStudioPreview2025.3.4': workingStudio(root, 'Studio C'),
        'AndroidStudio2025.3.4': workingStudio(root, 'Studio D'),
      };
      records.forEach((folder, studio) {
        writeStudioRecord(google, folder, studio);
      });
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, studioJdkHome(records['AndroidStudio2025.3.4']!));
    }, testOn: '!mac-os');

    test('equal versions keep the install found first, as in Flutter', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final first = workingStudio(root, 'Studio A');
      final second = workingStudio(root, 'Studio Z');
      // Flutter reads ~/.AndroidStudio* before ~/.cache/Google/AndroidStudio*.
      writeStudioRecord(home, '.AndroidStudio2025.3.4', first);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.3.4',
        second,
      );
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, studioJdkHome(first));
    }, testOn: '!mac-os');

    test('if android-studio-dir is set, only that install counts', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final configured = brokenStudio(root);
      final newer = workingStudio(root);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2025.3.4',
        newer,
      );
      final lookup = await locateFlutterJava(
        fakeEnvironment({...homeVars(home), 'JAVA_HOME': 'jh'}),
        {'android-studio-dir': configured},
        runner,
      );
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [skippedNote(configured)]);
    });

    test('a Studio older than 2022 has its JDK in jre', () async {
      final root = tempDir();
      final home = p.join(root.path, 'home');
      final studio = p.join(root.path, 'Old Studio');
      final jre = p.join(studio, 'jre');
      File(javaIn(jre)).createSync(recursive: true);
      runner.when(javaIn(jre), ['-version'], java21);
      writeStudioRecord(
        p.join(home, '.cache', 'Google'),
        'AndroidStudio2021.3',
        studio,
      );
      final location = await locate(fakeEnvironment(homeVars(home)), {});
      expect(location!.home, jre);
    }, testOn: '!mac-os');

    test(
      'Windows: an install with no .home record is not used, as in Flutter',
      () async {
        final programFiles = tempDir();
        workingStudio(Directory(p.join(programFiles.path, 'Android')));
        final location = await locate(
          fakeEnvironment({
            'ProgramFiles': programFiles.path,
            'JAVA_HOME': 'jh',
          }),
          {},
        );
        expect(location!.source, JavaSource.javaHome);
      },
      testOn: 'windows',
    );
  });

  group('macOS, searched as Flutter searches it', () {
    const mac = HostOs.macos;
    const spotlightQuery =
        'kMDItemCFBundleIdentifier="com.google.android.studio*"';
    late Directory root;
    late String apps;
    late String homeApps;

    setUp(() {
      root = tempDir();
      apps = p.join(root.path, 'Applications');
      homeApps = p.join(root.path, 'home', 'Applications');
      Directory(apps).createSync(recursive: true);
      Directory(homeApps).createSync(recursive: true);
    });

    /// An Android Studio app at [bundle] with an Info.plist, whose bundled
    /// JDK runs, or fails when [works] is false.
    String macStudio(
      String bundle, {
      String? version,
      bool works = true,
      bool toolbox = false,
    }) {
      fakeStudio(
        Directory(p.dirname(bundle)),
        name: p.basename(bundle),
        os: mac,
      );
      writeInfoPlist(bundle, version: version, toolbox: toolbox);
      runner.when(javaIn(studioJdkHome(bundle, os: mac), mac), [
        '-version',
      ], works ? java21 : brokenJava);
      return bundle;
    }

    Future<JavaLookup> lookUp({
      Map<String, Object?> settings = const {},
      Map<String, String> vars = const {},
    }) => locateFlutterJava(
      fakeEnvironment({'HOME': p.join(root.path, 'home'), ...vars}, os: mac),
      settings,
      runner,
      macAppFolders: [apps, homeApps],
    );

    String toolboxNote(String bundle) =>
        'Android Studio at $bundle is a JetBrains Toolbox launcher. Flutter '
        'skips it, and finds Toolbox installs only through Spotlight.';

    test('finds any Android Studio*.app, in a subfolder too', () async {
      final studio = macStudio(
        p.join(apps, 'Dev Tools', 'Android Studio Preview.app'),
        version: '2025.1',
      );
      final lookup = await lookUp();
      expect(lookup.location!.source, JavaSource.androidStudio);
      expect(lookup.location!.home, studioJdkHome(studio, os: mac));
    });

    test('never looks inside another app bundle', () async {
      macStudio(
        p.join(apps, 'Tools.app', 'Android Studio.app'),
        version: '2025.1',
      );
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('does not follow a link to a folder', () async {
      final real = macStudio(
        p.join(root.path, 'elsewhere', 'Android Studio.app'),
        version: '2025.1',
      );
      Link(p.join(apps, 'Android Studio.app')).createSync(real);
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('newest version first, and equal versions keep the one found '
        'first', () async {
      macStudio(p.join(apps, 'Android Studio.app'), version: '2024.3.1');
      // Sorted by name, "Android Studio Preview.app" comes before
      // "Android Studio.app", and /Applications before ~/Applications.
      final first = macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: '2025.1.2',
      );
      macStudio(p.join(homeApps, 'Android Studio.app'), version: '2025.1.2');
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(first, os: mac));
    });

    test('reads the EAP version of a Preview build', () async {
      macStudio(p.join(apps, 'Android Studio.app'), version: '2024.2.1');
      final eap = macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: 'EAP AI-242.21829.142.2422.12358220',
      );
      final lookup = await lookUp();
      // 2422 reads as 2024.2.2, newer than 2024.2.1.
      expect(lookup.location!.home, studioJdkHome(eap, os: mac));
    });

    test("an EAP version it can't read is unknown, so a known version "
        'wins', () async {
      final release = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2024.2.1',
      );
      macStudio(
        p.join(apps, 'Android Studio Preview.app'),
        version: 'EAP AI-242.21829.142.242.12358220',
      );
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(release, os: mac));
    });

    // Review Focus 2: a Toolbox-only Mac with Spotlight off (mdfind is not
    // faked, so it "can't start").
    test('skips a JetBrains Toolbox launcher, and says why', () async {
      final launcher = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [toolboxNote(launcher)]);
      expect(runner.calls.where((call) => call.endsWith(' -version')), isEmpty);
    });

    test('finds a Toolbox install, or a renamed app, through '
        'Spotlight', () async {
      macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final real = macStudio(
        p.join(root.path, 'Toolbox', 'apps', 'AS.app'),
        version: '2025.1.3',
      );
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 0, stdout: '$real\n'));
      final lookup = await lookUp();
      expect(lookup.location!.home, studioJdkHome(real, os: mac));
    });

    test('ignores a Spotlight query that fails', () async {
      final other = macStudio(
        p.join(root.path, 'Else', 'AS.app'),
        version: '2025.1',
      );
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 1, stdout: '$other\n'));
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
    });

    test('adds each Spotlight result once, and skips ones that no longer '
        'exist', () async {
      final broken = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        works: false,
      );
      final gone = p.join(root.path, 'gone', 'Android Studio.app');
      runner.when('mdfind', [
        spotlightQuery,
      ], RunResult(exitCode: 0, stdout: '$broken\n$gone\n'));
      final lookup = await lookUp(vars: {'JAVA_HOME': 'jh'});
      expect(lookup.location!.source, JavaSource.javaHome);
      expect(lookup.skipped, [skippedNote(broken)]);
    });

    test('reads Info.plist through plutil when plutil runs', () async {
      final bundle = p.join(apps, 'Android Studio.app');
      // A binary plist, which only plutil can read.
      final plist = File(p.join(bundle, 'Contents', 'Info.plist'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xd1, 0x01]);
      runner.when(
        '/usr/bin/plutil',
        ['-convert', 'xml1', '-o', '-', plist.path],
        const RunResult(
          exitCode: 0,
          stdout:
              '<plist version="1.0"><dict><key>CFBundleShortVersionString'
              '</key><string>2021.1.1</string></dict></plist>',
        ),
      );
      // Android Studio 2020 and 2021 keep their JDK in jre on macOS.
      final jre = p.join(bundle, 'Contents', 'jre', 'Contents', 'Home');
      File(javaIn(jre, mac)).createSync(recursive: true);
      runner.when(javaIn(jre, mac), ['-version'], java21);
      final lookup = await lookUp();
      expect(lookup.location!.home, jre);
    });

    test('android-studio-dir may name the bundle or its Contents folder, '
        'and then only it counts', () async {
      final configured = macStudio(
        p.join(root.path, 'Custom', 'Android Studio.app'),
        version: '2024.1',
      );
      macStudio(p.join(apps, 'Android Studio.app'), version: '2025.1');
      final lookup = await lookUp(
        settings: {'android-studio-dir': p.join(configured, 'Contents')},
      );
      expect(lookup.location!.home, studioJdkHome(configured, os: mac));
      expect(runner.calls, isNot(contains(startsWith('mdfind'))));
    });

    test('a configured Toolbox launcher is dropped, and the search runs as '
        'if nothing were set', () async {
      final launcher = macStudio(
        p.join(root.path, 'Custom', 'Android Studio.app'),
        version: '2025.1',
        toolbox: true,
      );
      final studio = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2024.1',
      );
      final lookup = await lookUp(settings: {'android-studio-dir': launcher});
      expect(lookup.location!.home, studioJdkHome(studio, os: mac));
      expect(lookup.skipped, [toolboxNote(launcher)]);
    });

    test('no JDK: the installs passed over still come back', () async {
      final broken = macStudio(
        p.join(apps, 'Android Studio.app'),
        version: '2025.1',
        works: false,
      );
      final lookup = await lookUp();
      expect(lookup.location, isNull);
      expect(lookup.skipped, [skippedNote(broken)]);
    });
  });
}
