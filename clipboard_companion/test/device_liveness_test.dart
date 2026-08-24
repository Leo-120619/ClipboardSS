import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

void main() {
  test('disconnect is shown only for an enabled device that is online', () {
    expect(isDeviceConnectionActive(enabled: true, online: true), isTrue);
    expect(isDeviceConnectionActive(enabled: true, online: false), isFalse);
    expect(isDeviceConnectionActive(enabled: false, online: true), isFalse);
  });

  test('reconnection prefers a live address and ignores another device', () {
    final peer = matchingReconnectPeer(
      deviceId: 'target',
      mdnsPeers: [
        Peer(id: 'other', name: 'Other', host: '10.0.0.8', port: 51888),
      ],
      sweptPeers: [
        Peer(id: 'target', name: 'Target', host: '10.0.0.42', port: 51888),
      ],
    );

    expect(peer?.host, '10.0.0.42');
  });

  test('network lifecycle transitions run in request order', () async {
    final queue = AsyncOperationQueue();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = queue.run(() async {
      events.add('pause-start');
      await releaseFirst.future;
      events.add('pause-end');
    });
    final second = queue.run(() async {
      events.add('resume');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['pause-start']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['pause-start', 'pause-end', 'resume']);
  });

  test(
    'a device visible over mDNS is online only after its address responds',
    () async {
      final probed = <String>[];

      final online = await computeDeviceLiveness(
        devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
        mdnsPeers: [
          Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888),
        ],
        probe: (host) async {
          probed.add(host);
          return Peer(id: 'a', name: 'Mac', host: host, port: 51888);
        },
      );

      expect(online, {'a': true});
      expect(probed, ['192.168.0.4']);
    },
  );

  test('a stale mDNS address falls back to the stored address', () async {
    final probed = <String>[];

    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
      mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.8', port: 51888)],
      probe: (host) async {
        probed.add(host);
        return host == '10.0.0.9'
            ? Peer(id: 'a', name: 'Mac', host: host, port: 51888)
            : null;
      },
    );

    expect(online, {'a': true});
    expect(probed, ['10.0.0.8', '10.0.0.9']);
  });

  test('a probe returning the matching device id marks it online', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
      mdnsPeers: [],
      probe: (host) async => Peer(id: 'b', name: 'PC', host: host, port: 51888),
    );

    expect(online, {'b': true});
  });

  test('a probe that fails or times out marks the device offline', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
      mdnsPeers: [],
      probe: (host) async =>
          Peer(id: ' A-B ', name: 'Mac', host: host, port: 51888),
    );

    expect(online, {'b': false});
  });

  test('a host answering with a different device id is offline', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
      mdnsPeers: [],
      probe: (host) async =>
          Peer(id: 'someone-else', name: 'Other', host: host, port: 51888),
    );

    expect(online, {'b': false});
  });

  test('a device with no stored host is offline and is not probed', () async {
    final probed = <String>[];

    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'c', name: 'Legacy')],
      mdnsPeers: [],
      probe: (host) async {
        probed.add(host);
        return null;
      },
    );

    expect(online, {'c': false});
    expect(probed, isEmpty);
  });

  test('liveness is reported per device across a mixed set', () async {
    final online = await computeDeviceLiveness(
      devices: [
        PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9'),
        PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20'),
        PairedDevice(id: 'd', name: 'Off', host: '192.168.0.30'),
      ],
      mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.9', port: 51888)],
      probe: (host) async => host == '10.0.0.9'
          ? Peer(id: 'a', name: 'Mac', host: host, port: 51888)
          : host == '192.168.0.20'
          ? Peer(id: 'b', name: 'PC', host: host, port: 51888)
          : null,
    );

    expect(online, {'a': true, 'b': true, 'd': false});
  });

  test(
    'liveness is independent of the manual connected (pause) flag',
    () async {
      final online = await computeDeviceLiveness(
        devices: [
          PairedDevice(
            id: 'a',
            name: 'Mac',
            host: '10.0.0.9',
            connected: false,
          ),
        ],
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.9', port: 51888)],
        probe: (host) async =>
            Peer(id: 'a', name: 'Mac', host: host, port: 51888),
      );

      expect(online, {'a': true});
    },
  );

  test('device ids are canonicalised when reporting liveness', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: '  A-B  ', name: 'Mac', host: '10.0.0.9')],
      mdnsPeers: [Peer(id: 'a-b', name: 'Mac', host: '10.0.0.9', port: 51888)],
      probe: (host) async =>
          Peer(id: ' A-B ', name: 'Mac', host: host, port: 51888),
    );

    expect(online, {'a-b': true});
  });
}
