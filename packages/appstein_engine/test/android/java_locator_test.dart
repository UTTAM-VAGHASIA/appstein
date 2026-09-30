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

    test('newest version first; a Preview of the same version comes after '
        'the release', () async {
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
}
