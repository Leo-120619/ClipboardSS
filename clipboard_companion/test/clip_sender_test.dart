import 'dart:convert';
import 'dart:async';

import 'package:clipboard_companion/core/clip_sender.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fake_pair_key_storage.dart';

void main() {
  test('broadcast reports skipped peers and HTTP failures', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pairedStore = PairedDeviceStore(
      prefs,
      keyStorage: FakePairKeyStorage(),
    );
    final pairedId = '550e8400-e29b-41d4-a716-446655440000';
    await pairedStore.addDevice(
      PairedDevice(id: pairedId, name: 'Mac'),
      SecretKey(List<int>.filled(32, 1)),
    );

    final sender = ClipSender(
      identity: DeviceIdentity(
        id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
        name: 'Android',
      ),
      pairedStore: pairedStore,
      client: MockClient((request) async {
        return http.Response('Nope', 500);
      }),
    );

    final result = await sender.broadcast(_clip(), [
      Peer(id: pairedId, name: 'Mac', host: '10.0.0.2', port: 8080),
      Peer(
        id: 'a4f030ff-f094-4a28-a3d7-a0d4f0186545',
        name: 'Other',
        host: '10.0.0.3',
        port: 8080,
      ),
    ]);

    expect(result.successCount, 0);
    expect(result.failureCount, 1);
    expect(result.skippedUnpairedCount, 1);
    expect(result.hasVisiblePeers, isTrue);
    expect(result.hasPairedTargets, isTrue);
  });

  test('broadcast wraps IPv6 literal hosts in URLs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pairedStore = PairedDeviceStore(
      prefs,
      keyStorage: FakePairKeyStorage(),
    );
    final peerId = '550e8400-e29b-41d4-a716-446655440000';
    await pairedStore.addDevice(
      PairedDevice(id: peerId, name: 'Mac'),
      SecretKey(List<int>.filled(32, 1)),
    );

    Uri? observedUrl;
    final sender = ClipSender(
      identity: DeviceIdentity(
        id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
        name: 'Android',
      ),
      pairedStore: pairedStore,
      client: MockClient((request) async {
        observedUrl = request.url;
        return http.Response('OK', 200);
      }),
    );

    final result = await sender.broadcast(_clip(), [
      Peer(id: peerId, name: 'Mac', host: 'fe80::1', port: 8080),
    ]);

    expect(result.successCount, 1);
    expect(observedUrl, Uri.parse('http://[fe80::1]:8080/v1/clip'));
  });

  test('broadcast bounds stalled HTTP requests', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pairedStore = PairedDeviceStore(
      prefs,
      keyStorage: FakePairKeyStorage(),
    );
    const peerId = '550e8400-e29b-41d4-a716-446655440000';
    await pairedStore.addDevice(
      PairedDevice(id: peerId, name: 'Mac'),
      SecretKey(List<int>.filled(32, 1)),
    );
    final sender = ClipSender(
      identity: DeviceIdentity(
        id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
        name: 'Android',
      ),
      pairedStore: pairedStore,
      client: MockClient((request) => Completer<http.Response>().future),
      requestTimeout: const Duration(milliseconds: 10),
    );

    final result = await sender.broadcast(_clip(), [
      Peer(id: peerId, name: 'Mac', host: '10.0.0.2', port: 51888),
    ]);

    expect(result.failureCount, 1);
  });

  test(
    'broadcast seals for the recipient and skips peers needing an update',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final pairedStore = PairedDeviceStore(
        prefs,
        keyStorage: FakePairKeyStorage(),
      );
      const currentId = '550e8400-e29b-41d4-a716-446655440000';
      const outdatedId = 'a4f030ff-f094-4a28-a3d7-a0d4f0186545';
      final key = SecretKey(List<int>.filled(32, 1));
      await pairedStore.addDevice(
        PairedDevice(id: currentId, name: 'Mac'),
        key,
      );
      await pairedStore.addDevice(
        PairedDevice(id: outdatedId, name: 'Old'),
        key,
      );

      final bodies = <String>[];
      final sender = ClipSender(
        identity: DeviceIdentity(
          id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
          name: 'Android',
        ),
        pairedStore: pairedStore,
        client: MockClient((request) async {
          bodies.add(request.body);
          return http.Response('OK', 200);
        }),
      );

      final result = await sender.broadcast(_clip(), [
        Peer(id: currentId, name: 'Mac', host: '10.0.0.2', port: 51888),
        Peer(
          id: outdatedId,
          name: 'Old',
          host: '10.0.0.3',
          port: 51888,
          protocolVersion: 1,
        ),
      ]);

      expect(result.successCount, 1);
      expect(result.needsUpdateCount, 1);
      expect(bodies, hasLength(1));
      final envelope = ClipEnvelope.fromJson(jsonDecode(bodies.single));
      expect(envelope.v, 2);
      final opened = await CryptoEnvelopeUtils.open(
        envelope,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: currentId,
        pairKey: key,
      );
      expect(opened.id, _clip().id);
    },
  );

  test('broadcast counts a 426 answer as needing an update', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pairedStore = PairedDeviceStore(
      prefs,
      keyStorage: FakePairKeyStorage(),
    );
    const peerId = '550e8400-e29b-41d4-a716-446655440000';
    await pairedStore.addDevice(
      PairedDevice(id: peerId, name: 'Mac'),
      SecretKey(List<int>.filled(32, 1)),
    );
    final sender = ClipSender(
      identity: DeviceIdentity(
        id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
        name: 'Android',
      ),
      pairedStore: pairedStore,
      client: MockClient(
        (request) async =>
            http.Response('{"status":"upgradeRequired","minVersion":2}', 426),
      ),
    );

    final result = await sender.broadcast(_clip(), [
      Peer(id: peerId, name: 'Mac', host: '10.0.0.2', port: 51888),
    ]);

    expect(result.failureCount, 1);
    expect(result.needsUpdateCount, 1);
  });

  test(
    'broadcast reports a stale answer as clock out of sync with that device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final pairedStore = PairedDeviceStore(
        prefs,
        keyStorage: FakePairKeyStorage(),
      );
      const peerId = '550e8400-e29b-41d4-a716-446655440000';
      await pairedStore.addDevice(
        PairedDevice(id: peerId, name: 'Mac'),
        SecretKey(List<int>.filled(32, 1)),
      );
      final sender = ClipSender(
        identity: DeviceIdentity(
          id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
          name: 'Android',
        ),
        pairedStore: pairedStore,
        client: MockClient(
          (request) async => http.Response('{"status":"stale"}', 400),
        ),
      );

      final result = await sender.broadcast(_clip(), [
        Peer(id: peerId, name: 'Mac', host: '10.0.0.2', port: 51888),
      ]);

      expect(result.failureCount, 1);
      expect(result.needsUpdateCount, 0);
      expect(result.clockOutOfSyncPeerNames, ['Mac']);
      expect(
        clockOutOfSyncMessage(result.clockOutOfSyncPeerNames),
        'Clock out of sync with Mac.',
      );
    },
  );
}

ClipPayload _clip() {
  return ClipPayload(
    id: 'clip-1',
    type: ClipType.text,
    createdAt: DateTime(2026, 7, 8),
    text: 'hello',
    contentHash: base64Encode(utf8.encode('hash')),
    sourceDeviceName: 'Android',
  );
}
