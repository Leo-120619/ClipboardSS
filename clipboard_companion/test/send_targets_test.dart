import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'send targets route paired devices to their verified host, never an mDNS-claimed one',
    () {
      final mdns = [
        Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888),
        Peer(id: 'x', name: 'Stranger', host: '192.168.0.50', port: 51888),
      ];
      final paired = [
        PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9'),
        PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20'),
        PairedDevice(id: 'c', name: 'Legacy'),
      ];

      final targets = composeSendTargets(mdns, paired);

      expect(targets.length, 3);
      expect(targets.firstWhere((p) => p.id == 'a').host, '10.0.0.9');
      expect(targets.firstWhere((p) => p.id == 'b').host, '192.168.0.20');
    },
  );

  test('a paired device advertising an older v over mDNS is not sent to', () {
    final targets = composeSendTargets(
      [
        Peer(
          id: 'a',
          name: 'Old',
          host: '192.168.0.4',
          port: 51888,
          protocolVersion: 1,
        ),
      ],
      [PairedDevice(id: 'a', name: 'Old', host: '10.0.0.9')],
    );

    expect(targets.single.needsUpdate, isTrue);
    expect(targets.single.host, '10.0.0.9');
  });

  test('a file target ignores an mDNS-claimed address', () {
    final device = PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9');
    expect(
      resolveVerifiedPeer(
        device: device,
        online: true,
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.66', port: 51888)],
      )?.host,
      '10.0.0.9',
    );
  });

  test('stored-host targets recorded as outdated carry the older version', () {
    final paired = [
      PairedDevice(id: 'old', name: 'Old', host: '192.168.0.30'),
      PairedDevice(id: 'new', name: 'New', host: '192.168.0.31'),
    ];

    final targets = composeSendTargets(
      const [],
      paired,
      outdatedDeviceIds: {'old'},
    );

    expect(targets.firstWhere((p) => p.id == 'old').needsUpdate, isTrue);
    expect(targets.firstWhere((p) => p.id == 'new').needsUpdate, isFalse);
  });

  test(
    'a file target resolved from the stored host keeps the probed version',
    () {
      final device = PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9');
      expect(
        resolveVerifiedPeer(
          device: device,
          online: true,
          mdnsPeers: const [],
          outdatedDeviceIds: {'a'},
        )?.needsUpdate,
        isTrue,
      );
    },
  );

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
