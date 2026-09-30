import 'package:test/test.dart';

import '../tool/src/markdown.dart';

void main() {
  test('FenceTracker tells prose, fence lines and code apart', () {
    final fences = FenceTracker();
    expect(
      [
        for (final line in ['a', '  ```text', 'b', '```', 'c'])
          fences.next(line),
      ],
      [
        FenceLine.prose,
        FenceLine.open,
        FenceLine.code,
        FenceLine.close,
        FenceLine.prose,
      ],
    );
  });

  test('fileLinks keeps file links, decoded and without the anchor', () {
    expect(
      [
        for (final link in fileLinks(
          '[a](my%20page.md#top "t") [b](https://dart.dev) [c](#here) '
          '[d](mailto:x@example.com) [e](../e.md)',
        ))
          '${link.target} -> ${link.path}',
      ],
      ['my%20page.md#top -> my page.md', '../e.md -> ../e.md'],
    );
  });
}
