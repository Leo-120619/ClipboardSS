import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('send targets union: live peer wins, stored host used otherwise', () {
    final mdns = [Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888)];
    final paired = [
      PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9'),
      PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20'),
      PairedDevice(id: 'c', name: 'Legacy'),
    ];

    final targets = composeSendTargets(mdns, paired);

    expect(targets.length, 2);
    expect(targets.firstWhere((p) => p.id == 'a').host, '192.168.0.4');
    expect(targets.firstWhere((p) => p.id == 'b').host, '192.168.0.20');
  });

  test('file target resolution rejects offline and paused devices', () {
    final device = PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9');
    final paused = PairedDevice(
      id: 'a',
      name: 'Mac',
      host: '10.0.0.9',
      connected: false,
    );

    expect(
      resolveVerifiedPeer(device: device, online: false, mdnsPeers: const []),
      isNull,
    );
    expect(
      resolveVerifiedPeer(device: paused, online: true, mdnsPeers: const []),
      isNull,
    );
    expect(
      resolveVerifiedPeer(
        device: device,
        online: true,
        mdnsPeers: const [],
      )?.host,
      '10.0.0.9',
    );
  });

  test('join candidates try mDNS first then swept peers', () {
    final mdns = [
      Peer(id: 'a', name: 'Stale', host: '192.168.0.4', port: 51888),
    ];
    final swept = [
      Peer(id: 'b', name: 'Mac', host: '192.168.0.20', port: 51888),
      Peer(id: 'a', name: 'Stale duplicate', host: '192.168.0.5', port: 51888),
    ];

    final targets = composeJoinCandidates(mdns, swept);

    expect(targets.map((p) => p.id).toList(), ['a', 'b']);
    expect(targets[0].host, '192.168.0.4');
    expect(targets[1].host, '192.168.0.20');
  });
}
