import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a device visible over mDNS is online without probing', () async {
    final probed = <String>[];

    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
      mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888)],
      probe: (host) async {
        probed.add(host);
        return null;
      },
    );

    expect(online, {'a': true});
    expect(probed, isEmpty);
  });

  test('a probe returning the matching device id marks it online', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
      mdnsPeers: [],
      probe: (host) async =>
          Peer(id: 'b', name: 'PC', host: host, port: 51888),
    );

    expect(online, {'b': true});
  });

  test('a probe that fails or times out marks the device offline', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
      mdnsPeers: [],
      probe: (host) async => null,
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
      probe: (host) async => host == '192.168.0.20'
          ? Peer(id: 'b', name: 'PC', host: host, port: 51888)
          : null,
    );

    expect(online, {'a': true, 'b': true, 'd': false});
  });

  test('liveness is independent of the manual connected (pause) flag', () async {
    final online = await computeDeviceLiveness(
      devices: [
        PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9', connected: false),
      ],
      mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.9', port: 51888)],
      probe: (host) async => null,
    );

    expect(online, {'a': true});
  });

  test('device ids are canonicalised when reporting liveness', () async {
    final online = await computeDeviceLiveness(
      devices: [PairedDevice(id: '  A-B  ', name: 'Mac', host: '10.0.0.9')],
      mdnsPeers: [Peer(id: 'a-b', name: 'Mac', host: '10.0.0.9', port: 51888)],
      probe: (host) async => null,
    );

    expect(online, {'a-b': true});
  });
}
