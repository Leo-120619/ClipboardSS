import 'dart:io';

import 'package:clipboard_companion/core/subnet_sweeper.dart';
import 'package:clipboard_companion/core/sweep_interfaces.dart';
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

  group('hostAddresses derives the range from the prefix', () {
    test('/23 covers both halves, minus network, broadcast and self', () {
      final hosts = SubnetSweeper.hostAddresses('10.0.3.20', 23);
      expect(hosts.length, 509);
      expect(hosts.first, '10.0.2.1');
      expect(hosts.last, '10.0.3.254');
      expect(hosts.contains('10.0.2.255'), isTrue);
      expect(hosts.contains('10.0.3.0'), isTrue);
      expect(hosts.contains('10.0.3.20'), isFalse);
      expect(hosts.contains('10.0.2.0'), isFalse);
      expect(hosts.contains('10.0.3.255'), isFalse);
    });

    test('/26 stays inside the own block', () {
      final hosts = SubnetSweeper.hostAddresses('192.168.1.70', 26);
      expect(hosts.length, 61);
      expect(hosts.first, '192.168.1.65');
      expect(hosts.last, '192.168.1.126');
    });

    test('masks wider than /22 are capped at the /22 holding self', () {
      final hosts = SubnetSweeper.hostAddresses('10.20.30.40', 8);
      expect(hosts.length, 1021);
      expect(hosts.first, '10.20.28.1');
      expect(hosts.last, '10.20.31.254');
    });

    test('point-to-point and invalid input yield nothing', () {
      expect(SubnetSweeper.hostAddresses('10.0.0.1', 31), isEmpty);
      expect(SubnetSweeper.hostAddresses('10.0.0.1', 32), isEmpty);
      expect(SubnetSweeper.hostAddresses('10.0.0.1', 33), isEmpty);
      expect(SubnetSweeper.hostAddresses('10.0.0', 24), isEmpty);
      expect(SubnetSweeper.hostAddresses('10.0.0.300', 24), isEmpty);
    });
  });

  group('pickInterface', () {
    SweepInterface iface(
      String name,
      String address, {
      int prefix = 24,
      bool isDefault = false,
    }) => SweepInterface(
      name: name,
      address: address,
      prefixLength: prefix,
      isDefaultRoute: isDefault,
    );

    test('prefers the interface holding the default route', () {
      final picked = SubnetSweeper.pickInterface([
        iface('rmnet0', '10.44.0.2'),
        iface('wlan0', '192.168.1.5', prefix: 23, isDefault: true),
      ]);
      expect(picked?.name, 'wlan0');
      expect(picked?.prefixLength, 23);
    });

    test('a public default route falls back to a private LAN', () {
      final picked = SubnetSweeper.pickInterface([
        iface('pdp_ip0', '100.70.1.2', isDefault: true),
        iface('en0', '192.168.0.9'),
      ]);
      expect(picked?.name, 'en0');
    });

    test('without route info, Wi-Fi or Ethernet beats cellular', () {
      final picked = SubnetSweeper.pickInterface([
        iface('pdp_ip0', '10.12.0.4'),
        iface('rmnet_data0', '10.13.0.4'),
        iface('en0', '172.20.10.3', prefix: 28),
      ]);
      expect(picked?.name, 'en0');
    });

    test('loopback and public-only lists pick nothing', () {
      expect(
        SubnetSweeper.pickInterface([
          iface('lo0', '127.0.0.1', prefix: 8),
          iface('en0', '8.8.8.8'),
        ]),
        isNull,
      );
    });
  });

  test(
    'getifaddrs reads the same IPv4 addresses as dart:io, with masks',
    () async {
      final viaIo = <String>{
        for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final a in ni.addresses)
            if (!a.isLoopback) a.address,
      };
      final viaFfi = darwinInterfaces();
      expect(viaFfi.map((i) => i.address).toSet(), viaIo);
      for (final i in viaFfi) {
        expect(i.prefixLength, inInclusiveRange(1, 32));
      }
    },
    skip: Platform.isMacOS ? false : 'getifaddrs layout is BSD-only',
  );

  test('sweep starts from the picked interface and its mask', () async {
    final probed = <String>[];
    final client = MockClient((request) async {
      probed.add(request.url.host);
      return http.Response('', 404);
    });
    await SubnetSweeper.sweep(
      client: client,
      timeoutMs: 10,
      interfaces: () async => const [
        SweepInterface(name: 'rmnet0', address: '10.1.0.2', prefixLength: 24),
        SweepInterface(
          name: 'wlan0',
          address: '192.168.4.10',
          prefixLength: 28,
          isDefaultRoute: true,
        ),
      ],
    );
    expect(probed.toSet().length, 13);
    expect(probed.every((h) => h.startsWith('192.168.4.')), isTrue);
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
