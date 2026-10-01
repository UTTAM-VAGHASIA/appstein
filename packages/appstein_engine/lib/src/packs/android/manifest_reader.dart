import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../native/native_files.dart';

/// The namespace of `android:` attributes.
const androidNamespace = 'http://schemas.android.com/apk/res/android';

/// The namespace of `tools:` attributes (the manifest merger's).
const toolsNamespace = 'http://schemas.android.com/tools';

/// An attribute's value and the 1-based line it is written on.
final class ManifestAttribute {
  /// Creates the attribute.
  const ManifestAttribute(this.value, this.line);

  /// The value, as written (a resource such as `@string/app_name` stays a
  /// resource).
  final String value;

  /// The line of the attribute itself.
  final int line;
}

/// A `<uses-permission>` or `<uses-permission-sdk-23>` of the manifest.
final class ManifestPermission {
  /// Creates the permission.
  const ManifestPermission({
    required this.name,
    required this.line,
    this.maxSdkVersion,
    this.removed = false,
    this.sdk23 = false,
  });

  /// Its `android:name`, such as `android.permission.CAMERA`.
  final String name;

  /// The line of its `android:name`.
  final int line;

  /// Its `android:maxSdkVersion`, as written; null when unset.
  final String? maxSdkVersion;

  /// Whether it has `tools:node="remove"`: it removes the permission a
  /// plugin's manifest would add.
  final bool removed;

  /// Whether it is a `<uses-permission-sdk-23>`.
  final bool sdk23;
}

/// What `native.json` records from one `AndroidManifest.xml`.
final class ManifestFacts {
  /// Creates the facts.
  const ManifestFacts({
    this.label,
    this.icon,
    this.hasApplication = true,
    required this.permissions,
  });

  /// Whether the manifest has an `<application>` element. The debug and
  /// profile manifests of a new app have none.
  final bool hasApplication;

  /// `<application android:label>`; null when unset.
  final ManifestAttribute? label;

  /// `<application android:icon>`; null when unset.
  final ManifestAttribute? icon;

  /// The permissions directly under `<manifest>`, in file order.
  final List<ManifestPermission> permissions;
}

/// A manifest Appstein can't read.
final class ManifestFormatException implements Exception {
  /// Creates the exception.
  const ManifestFormatException(this.message, [this.line]);

  /// What is wrong, in the XML parser's words.
  final String message;

  /// The 1-based line, when known.
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}

/// Reads an `AndroidManifest.xml` with `package:xml`'s event parser, which
/// knows where each element starts.
///
/// Throws a [ManifestFormatException] when the text isn't well-formed XML
/// or its root isn't `<manifest>`.
ManifestFacts readManifest(String text) {
  ManifestAttribute? label;
  ManifestAttribute? icon;
  final permissions = <ManifestPermission>[];
  var depth = 0;
  var sawRoot = false;
  var hasApplication = false;
  try {
    for (final event in parseEvents(
      text,
      withLocation: true,
      withParent: true,
      validateNesting: true,
      validateDocument: true,
    )) {
      switch (event) {
        case XmlStartElementEvent():
          depth++;
          if (depth == 1) {
            if (event.localName != 'manifest') {
              throw ManifestFormatException(
                'the root element is <${event.name}>, not <manifest>',
                lineAt(text, event.start!),
              );
            }
            sawRoot = true;
          } else if (depth == 2) {
            ManifestAttribute? android(String local) =>
                _attribute(text, event, androidNamespace, local);
            switch (event.localName) {
              case 'application':
                hasApplication = true;
                label = android('label');
                icon = android('icon');
              case 'uses-permission' || 'uses-permission-sdk-23':
                if (android('name') case final name?) {
                  permissions.add(
                    ManifestPermission(
                      name: name.value,
                      line: name.line,
                      maxSdkVersion: android('maxSdkVersion')?.value,
                      removed:
                          _attribute(
                            text,
                            event,
                            toolsNamespace,
                            'node',
                          )?.value ==
                          'remove',
                      sdk23: event.localName == 'uses-permission-sdk-23',
                    ),
                  );
                }
            }
          }
          if (event.isSelfClosing) depth--;
        case XmlEndElementEvent():
          depth--;
        default:
          break;
      }
    }
  } on XmlParserException catch (error) {
    throw ManifestFormatException(error.message, _line(error.line));
  } on XmlTagException catch (error) {
    throw ManifestFormatException(error.message, _line(error.line));
  } on XmlException catch (error) {
    throw ManifestFormatException(error.message);
  }
  if (!sawRoot) {
    throw const ManifestFormatException('there is no <manifest> element');
  }
  return ManifestFacts(
    label: label,
    icon: icon,
    hasApplication: hasApplication,
    permissions: permissions,
  );
}

int? _line(int line) => line > 0 ? line : null;

/// The attribute [local] in [namespace] of [event], with the line it is
/// written on (found in the element's own text).
ManifestAttribute? _attribute(
  String text,
  XmlStartElementEvent event,
  String namespace,
  String local,
) {
  for (final attribute in event.attributes) {
    if (attribute.localName != local || attribute.namespaceUri != namespace) {
      continue;
    }
    final start = event.start!;
    final element = text.substring(start, event.stop ?? text.length);
    final match = RegExp(
      '(^|\\s)${RegExp.escape(attribute.name)}\\s*=',
    ).firstMatch(element);
    final offset = match == null ? 0 : match.start + match.group(1)!.length;
    return ManifestAttribute(attribute.value, lineAt(text, start + offset));
  }
  return null;
}
