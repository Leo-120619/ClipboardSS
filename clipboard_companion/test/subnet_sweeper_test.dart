import 'package:clipboard_companion/core/subnet_sweeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('/24 enumeration excludes self, network, broadcast', () {
    final hosts = SubnetSweeper.hostAddresses('192.168.0.9', 24);

    expect(hosts.length, 253);
    expect(hosts.contains('192.168.0.4'), isTrue);
    expect(hosts.contains('192.168.0.9'), isFalse);
    expect(hosts.contains('192.168.0.0'), isFalse);
    expect(hosts.contains('192.168.0.255'), isFalse);
  });

  test('probeHost reads GET /v1/id from the fixed port', () async {
    Uri? requestedUri;
    final client = MockClient((request) async {
      requestedUri = request.url;
      return http.Response(
        '{"deviceId":"ABC","deviceName":"Mac","v":1}',
        200,
        headers: {'Content-Type': 'application/json'},
      );
    });

    final peer = await SubnetSweeper.probeHost(
      '192.168.0.4',
      client: client,
      timeout: const Duration(milliseconds: 10),
    );

    expect(requestedUri, Uri.parse('http://192.168.0.4:51888/v1/id'));
    expect(peer, isNotNull);
    expect(peer!.id, 'abc');
    expect(peer.name, 'Mac');
    expect(peer.host, '192.168.0.4');
    expect(peer.port, 51888);
  });
}
