import 'package:clipboard_companion/core/peer_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bestHostAddress prefers IPv4 over IPv6', () {
    expect(
      PeerBrowser.bestHostAddress(['fe80::1', '192.168.1.20']),
      '192.168.1.20',
    );
  });

  test('peerFromAttributes filters out the device\'s own advertised service', () {
    final peer = PeerBrowser.peerFromAttributes(
      serviceName: 'my-service',
      attrs: {'v': '1', 'deviceId': 'ABC-123', 'deviceName': 'Android Device'},
      host: '192.168.1.20',
      port: 5000,
      selfId: 'abc-123',
    );

    expect(peer, isNull);
  });

  test('peerFromAttributes returns a peer for a different device', () {
    final peer = PeerBrowser.peerFromAttributes(
      serviceName: 'my-service',
      attrs: {'v': '1', 'deviceId': 'DEF-456', 'deviceName': "Leonardo's MacBook"},
      host: '192.168.1.20',
      port: 5000,
      selfId: 'abc-123',
    );

    expect(peer, isNotNull);
    expect(peer!.id, 'def-456');
    expect(peer.name, "Leonardo's MacBook");
  });
}
