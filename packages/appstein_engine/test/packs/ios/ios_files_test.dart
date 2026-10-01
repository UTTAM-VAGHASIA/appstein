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
