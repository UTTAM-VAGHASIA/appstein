import 'package:appstein_engine/src/packs/ios/ios_files.dart';
import 'package:test/test.dart';

void main() {
  test("the generated Package.swift: the iOS version and the plugins' names "
      'only', () {
    final facts = readGeneratedPackage('''
// swift-tools-version: 5.9
let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("15.0")
    ],
    dependencies: [
        .package(name: "url_launcher_ios", path: "/Users/me/.pub-cache/url_launcher_ios/ios/url_launcher_ios"),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "camera_avfoundation", path: "/Users/me/.pub-cache/camera_avfoundation/ios/camera_avfoundation")
    ],
)
''');
    expect(facts.iosVersion, '15.0');
    expect(facts.iosVersionLine, 5);
    expect(facts.plugins, ['camera_avfoundation', 'url_launcher_ios']);
  });

  test('a Package.swift with no plugins', () {
    final facts = readGeneratedPackage(
      'platforms: [\n  .iOS("16.4")\n],\ndependencies: [\n\n],\n',
    );
    expect(facts.iosVersion, '16.4');
    expect(facts.plugins, isEmpty);
  });

  test("the Podfile's platform line, and a commented one", () {
    final set = readPodfile(
      "# Uncomment this line\n  platform :ios, '13.0'\n\ntarget 'Runner' do\nend\n",
    );
    expect(set.version, '13.0');
    expect(set.line, 2);
    final commented = readPodfile("# platform :ios, '13.0'\n");
    expect(commented.line, isNull);
    final bare = readPodfile('platform :ios\n');
    expect(bare.line, 1);
    expect(bare.version, isNull);
    expect(bare.isExpression, isFalse);
  });

  test('a platform line that is not plain is uncertain, never a version', () {
    final cases = {
      'platform :ios, "#{ver}"\n': 'interpolated',
      "platform :ios, '13.0' if ENV['X']\n": 'modifier',
      "platform :ios, '13.0' unless CI # why\n": 'modifier',
      "platform :ios, '13.0' + suffix\n": 'expression',
      "if ENV['X']\n  platform :ios, '13.0'\nend\n": 'Ruby block',
      "unless ci\n  platform :ios, '13.0'\nend\n": 'Ruby block',
      "case x\nwhen 1\n  platform :ios, '13.0'\nend\n": 'Ruby block',
      "target 'Runner' do\n  platform :ios, '13.0'\nend\n": 'Ruby block',
      "if ENV['X'] # why\r\n  platform :ios, '13.0'\r\nend\r\n": 'Ruby block',
      "platform :ios, '12.0'\nplatform :ios, '13.0'\n":
          'set more than once (lines 1, 2)',
    };
    for (final MapEntry(key: podfile, value: why) in cases.entries) {
      final facts = readPodfile(podfile);
      expect(facts.version, isNull, reason: podfile);
      expect(facts.uncertain, contains(why), reason: podfile);
      expect(facts.line, isNotNull, reason: podfile);
    }
  });

  test('CRLF Podfiles read like LF ones, comments and blocks included', () {
    for (final eol in ['\n', '\r\n']) {
      String lines(List<String> parts) => parts.join(eol);
      final trailing = readPodfile(lines(["platform :ios, '15.0' # min", '']));
      expect(trailing.uncertain, isNull, reason: 'trailing comment');
      expect(trailing.version, '15.0');
      // An opener with a trailing comment is still counted.
      final inBlock = readPodfile(
        lines([
          "target 'Runner' do # app",
          "  platform :ios, '15.0'",
          'end',
          '',
        ]),
      );
      expect(inBlock.uncertain, contains('Ruby block'));
      final reason = inBlock.uncertain!;
      expect(reason, contains("doesn't follow"));
      expect(reason, isNot(contains('conditionally')));
    }
  });

  group("Flutter 3.47.5's Podfile template (cocoapods/Podfile-ios)", () {
    // The template, with the shape of its blocks kept.
    String template(String platformAt) {
      final head = [
        '# Uncomment this line to define a global platform for your project',
        platformAt == 'top'
            ? "platform :ios, '15.0' # min"
            : "# platform :ios, '15.0'",
        '',
        "ENV['COCOAPODS_DISABLE_STATS'] = 'true'",
        '',
        "project 'Runner', {",
        "  'Debug' => :debug,",
        "  'Release' => :release,",
        '}',
        '',
        'def flutter_root',
        "  path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)",
        '  unless File.exist?(path)',
        '    raise "#{path} must exist. If you\'re running pod install manually"',
        '  end',
        '',
        '  File.foreach(path) do |line|',
        '    matches = line.match(/FLUTTER_ROOT\\=(.*)/)',
        '    return matches[1].strip if matches',
        '  end',
        '  raise "FLUTTER_ROOT not found in #{path}"',
        'end',
        '',
        'flutter_ios_podfile_setup',
        '',
        "target 'Runner' do",
        '  use_frameworks!',
        "  target 'RunnerTests' do",
        '    inherit! :search_paths',
        '  end',
        'end',
        '',
        'post_install do |installer|',
        '  installer.pods_project.targets.each do |target|',
        '    flutter_additional_ios_build_settings(target)',
        '  end',
        'end',
      ];
      if (platformAt == 'end') head.add("platform :ios, '15.0' # min");
      return '${head.join('\n')}\n';
    }

    for (final eol in ['\n', '\r\n']) {
      for (final at in ['top', 'end']) {
        test(
          'platform :ios uncommented at the $at, ${eol == '\n' ? 'LF' : 'CRLF'}',
          () {
            final facts = readPodfile(template(at).replaceAll('\n', eol));
            expect(facts.uncertain, isNull);
            expect(facts.version, '15.0');
          },
        );
      }
    }

    test('commented out, it names no platform line', () {
      expect(readPodfile(template('none')).line, isNull);
    });
  });

  test(
    'the generated package knows whether FlutterFramework is a dependency',
    () {
      expect(
        readGeneratedPackage(
          '.iOS("15.0")\ndependencies: [ ]\n',
        ).hasFlutterFramework,
        isFalse,
      );
      expect(
        readGeneratedPackage(
          '.package(name: "FlutterFramework", path: "../FlutterFramework")\n',
        ).hasFlutterFramework,
        isTrue,
      );
    },
  );

  test('a closed block, a comment and a modifier-free line stay plain', () {
    final facts = readPodfile(
      "def helper\n  1\nend\nif x then y end\n"
      "platform :ios, '13.0' # if you change this\n",
    );
    expect(facts.uncertain, isNull);
    expect(facts.version, '13.0');
    expect(facts.line, 5);
  });

  test('a Podfile version set by a Ruby expression is not "no version"', () {
    for (final line in [
      r'platform :ios, $iOSVersion',
      "platform :ios, ENV['IOS_VER']",
    ]) {
      final facts = readPodfile('$line\n');
      expect(facts.version, isNull, reason: line);
      expect(facts.line, 1, reason: line);
      expect(facts.isExpression, isTrue, reason: line);
    }
  });
}
