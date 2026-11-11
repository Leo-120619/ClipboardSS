import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/peer_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bestHostAddress prefers IPv4 over IPv6', () {
    expect(
      PeerBrowser.bestHostAddress(['fe80::1', '192.168.1.20']),
      '192.168.1.20',
    );
  });

  test(
    'peerFromAttributes filters out the device\'s own advertised service',
    () {
      final peer = PeerBrowser.peerFromAttributes(
        serviceName: 'my-service',
        attrs: {
          'v': '1',
          'deviceId': 'ABC-123',
          'deviceName': 'Android Device',
        },
        host: '192.168.1.20',
        port: 5000,
        selfId: 'abc-123',
      );

      expect(peer, isNull);
    },
  );

  test('peerFromAttributes returns a peer for a different device', () {
    final peer = PeerBrowser.peerFromAttributes(
      serviceName: 'my-service',
      attrs: {
        'v': '2',
        'deviceId': 'DEF-456',
        'deviceName': "Leonardo's MacBook",
      },
      host: '192.168.1.20',
      port: 5000,
      selfId: 'abc-123',
    );

    expect(peer, isNotNull);
    expect(peer!.id, 'def-456');
    expect(peer.name, "Leonardo's MacBook");
  });

  test(
    'peerFromAttributes lists a v1 peer but marks it as needing an update',
    () {
      final peer = PeerBrowser.peerFromAttributes(
        serviceName: 'old',
        attrs: {'v': '1', 'deviceId': 'DEF-456', 'deviceName': 'Old Phone'},
        host: '192.168.1.21',
        port: 51888,
        selfId: 'abc-123',
      );

      expect(peer, isNotNull);
      expect(peer!.protocolVersion, 1);
      expect(peer.needsUpdate, isTrue);
    },
  );

  test('peerFromAttributes treats a v2 peer as current', () {
    final peer = PeerBrowser.peerFromAttributes(
      serviceName: 'new',
      attrs: {'v': '2', 'deviceId': 'DEF-456'},
      host: '192.168.1.21',
      port: 51888,
      selfId: 'abc-123',
    );
    expect(peer!.needsUpdate, isFalse);
  });

  test('deviceNeedsUpdate reads mDNS peers and probe results', () {
    final old = Peer(
      id: 'a',
      name: 'Old',
      host: 'h',
      port: 1,
      protocolVersion: 1,
    );
    final current = Peer(id: 'a', name: 'New', host: 'h', port: 1);
    expect(
      deviceNeedsUpdate(deviceId: 'A', mdnsPeers: [old], outdatedDeviceIds: {}),
      isTrue,
    );
    expect(
      deviceNeedsUpdate(
        deviceId: 'a',
        mdnsPeers: const [],
        outdatedDeviceIds: {'a'},
      ),
      isTrue,
    );
    expect(
      deviceNeedsUpdate(
        deviceId: 'a',
        mdnsPeers: [current],
        outdatedDeviceIds: {},
      ),
      isFalse,
    );
  });
}
