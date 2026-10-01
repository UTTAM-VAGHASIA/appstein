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
