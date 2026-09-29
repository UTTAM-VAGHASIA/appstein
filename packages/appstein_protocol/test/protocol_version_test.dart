import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('the first protocol version is 1', () {
    expect(protocolVersion, 1);
  });
}
