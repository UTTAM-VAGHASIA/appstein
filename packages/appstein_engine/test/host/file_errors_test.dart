import 'dart:io';

import 'package:appstein_engine/src/host/file_errors.dart';
import 'package:test/test.dart';

void main() {
  test("uses the operating system's reason when it gave one", () {
    expect(
      fileErrorReason(
        const FileSystemException(
          'Cannot open file',
          'appstein.yaml',
          OSError('Access is denied.', 5),
        ),
      ),
      'Access is denied.',
    );
  });

  test("falls back to Dart's message", () {
    expect(
      fileErrorReason(
        const FileSystemException(
          "Failed to decode data using encoding 'utf-8'",
          'appstein.yaml',
        ),
      ),
      "Failed to decode data using encoding 'utf-8'",
    );
    expect(
      fileErrorReason(
        const FileSystemException('Cannot open file', 'x', OSError()),
      ),
      'Cannot open file',
    );
  });
}
