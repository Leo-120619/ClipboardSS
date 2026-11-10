import 'dart:convert';

import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/clip_server.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/liveness_ping.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:clipboard_companion/core/replay_guard.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'dart:async';

import 'file_transfer_test_support.dart';

void main() {
  test('disconnect is shown only for an enabled device that is online', () {
    expect(isDeviceConnectionActive(enabled: true, online: true), isTrue);
    expect(isDeviceConnectionActive(enabled: true, online: false), isFalse);
    expect(isDeviceConnectionActive(enabled: false, online: true), isFalse);
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

  group('liveness decisions', () {
    test(
      'impostorAnsweringIdIsNotMarkedOnline: an mDNS or /v1/id claim without a valid pong is offline',
      () async {
        final report = await computeDeviceLiveness(
          devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
          mdnsPeers: [
            Peer(id: 'a', name: 'Mac', host: '10.0.0.66', port: 51888),
          ],
          ping: (_, _) async => PingOutcome.unverified,
        );

        expect(report.onlineIds, isEmpty);
      },
    );

    test('hostIsNotUpdatedWithoutValidPong', () async {
      final device = PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9');
      final report = await computeDeviceLiveness(
        devices: [device],
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.66', port: 51888)],
        ping: (_, host) async => host == '10.0.0.66'
            ? PingOutcome.upgradeRequired
            : PingOutcome.unverified,
      );

      expect(hostUpdates([device], report), isEmpty);
      expect(report.onlineIds, isEmpty);
    });

    test('validPongMarksOnlineAndUpdatesHost', () async {
      final device = PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9');
      final pinged = <String>[];
      final report = await computeDeviceLiveness(
        devices: [device],
        mdnsPeers: [
          Peer(id: 'a', name: 'Mac', host: '192.168.0.4', port: 51888),
        ],
        ping: (_, host) async {
          pinged.add(host);
          return host == '192.168.0.4'
              ? PingOutcome.alive
              : PingOutcome.unverified;
        },
      );

      expect(report.onlineIds, {'a'});
      expect(hostUpdates([device], report), {'a': '192.168.0.4'});
      expect(pinged, ['192.168.0.4']);
    });

    test('a valid pong clears an earlier 426 from another address', () async {
      final report = await computeDeviceLiveness(
        devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.66', port: 51888)],
        ping: (_, host) async => host == '10.0.0.66'
            ? PingOutcome.upgradeRequired
            : PingOutcome.alive,
      );

      expect(report.onlineIds, {'a'});
      expect(report.upgradeRequired, isEmpty);
    });

    test('a 426 to every ping marks the device outdated, not online', () async {
      final report = await computeDeviceLiveness(
        devices: [PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20')],
        mdnsPeers: [],
        ping: (_, _) async => PingOutcome.upgradeRequired,
      );

      expect(report.onlineIds, isEmpty);
      expect(report.upgradeRequired, {'b'});
    });

    test('a stale mDNS address falls back to the stored address', () async {
      final pinged = <String>[];
      final report = await computeDeviceLiveness(
        devices: [PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9')],
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.8', port: 51888)],
        ping: (_, host) async {
          pinged.add(host);
          return host == '10.0.0.9'
              ? PingOutcome.alive
              : PingOutcome.unverified;
        },
      );

      expect(report.verifiedHosts, {'a': '10.0.0.9'});
      expect(pinged, ['10.0.0.8', '10.0.0.9']);
    });

    test('a device with no stored host is offline and is not pinged', () async {
      final pinged = <String>[];
      final report = await computeDeviceLiveness(
        devices: [PairedDevice(id: 'c', name: 'Legacy')],
        mdnsPeers: [],
        ping: (_, host) async {
          pinged.add(host);
          return PingOutcome.unverified;
        },
      );

      expect(report.onlineIds, isEmpty);
      expect(pinged, isEmpty);
    });

    test('liveness is reported per device across a mixed set', () async {
      final report = await computeDeviceLiveness(
        devices: [
          PairedDevice(id: 'a', name: 'Mac', host: '10.0.0.9'),
          PairedDevice(id: 'b', name: 'PC', host: '192.168.0.20'),
          PairedDevice(id: 'd', name: 'Off', host: '192.168.0.30'),
        ],
        mdnsPeers: [Peer(id: 'a', name: 'Mac', host: '10.0.0.9', port: 51888)],
        ping: (device, _) async =>
            device.id == 'd' ? PingOutcome.unverified : PingOutcome.alive,
      );

      expect(report.onlineIds, {'a', 'b'});
    });

    test(
      'liveness is independent of the manual connected (pause) flag',
      () async {
        final report = await computeDeviceLiveness(
          devices: [
            PairedDevice(
              id: 'a',
              name: 'Mac',
              host: '10.0.0.9',
              connected: false,
            ),
          ],
          mdnsPeers: [
            Peer(id: 'a', name: 'Mac', host: '10.0.0.9', port: 51888),
          ],
          ping: (_, _) async => PingOutcome.alive,
        );

        expect(report.onlineIds, {'a'});
      },
    );

    test('device ids are canonicalised when reporting liveness', () async {
      final report = await computeDeviceLiveness(
        devices: [PairedDevice(id: '  A-B  ', name: 'Mac', host: '10.0.0.9')],
        mdnsPeers: [
          Peer(id: 'a-b', name: 'Mac', host: '10.0.0.9', port: 51888),
        ],
        ping: (_, _) async => PingOutcome.alive,
      );

      expect(report.onlineIds, {'a-b'});
    });
  });

  group('POST /v1/ping', () {
    const localId = 'aaaaaaaa-0000-0000-0000-000000000000';
    const deviceId = 'cccccccc-0000-0000-0000-000000000000';
    final key = SecretKey(List<int>.filled(32, 7));

    Future<Handler> makeHandler({SecretKey? knownKey}) async {
      final store = await makePairedStore(localId, knownKey ?? key);
      final identity = DeviceIdentity(id: deviceId, name: 'Companion');
      return ClipServer(
        identity: identity,
        pairingCoordinator: PairingCoordinator(
          identity: identity,
          pairedStore: store,
        ),
        pairedStore: store,
        onClipReceived: (_) {},
      ).buildHandler();
    }

    Future<(int, String)?> Function(String) wire(Handler handler) =>
        (body) async {
          final response = await handler(
            Request('POST', Uri.parse('http://localhost/v1/ping'), body: body),
          );
          return (response.statusCode, await response.readAsString());
        };

    Future<PingOutcome> ping(Future<(int, String)?> Function(String) post) =>
        LivenessPing.ping(
          deviceId: deviceId,
          localDeviceId: localId,
          pairKey: key,
          post: post,
        );

    test('a valid pong from the paired device proves it alive', () async {
      expect(await ping(wire(await makeHandler())), PingOutcome.alive);
    });

    test('an impostor without the pair key is not alive', () async {
      final impostor = await makeHandler(
        knownKey: SecretKey(List<int>.filled(32, 9)),
      );
      expect(await ping(wire(impostor)), PingOutcome.unverified);
    });

    test(
      'a pong captured for an earlier ping does not answer a new one',
      () async {
        final post = wire(await makeHandler());
        (int, String)? captured;
        expect(
          await ping((body) async => captured = await post(body)),
          PingOutcome.alive,
        );
        expect(await ping((_) async => captured), PingOutcome.unverified);
      },
    );

    test('a pong from another device, or a stale pong, is not alive', () async {
      final nonce = base64Encode(List<int>.generate(12, (i) => i));
      Future<PingOutcome> evaluate(String source, DateTime sentAt) async {
        final pong = await CryptoEnvelopeUtils.sealJson(
          {'pingNonce': nonce},
          purpose: EnvelopePurpose.pong,
          sourceDeviceId: source,
          recipientDeviceId: localId,
          pairKey: key,
          sentAt: sentAt,
        );
        return LivenessPing.evaluatePong(
          statusCode: 200,
          body: jsonEncode(pong.toJson()),
          pingNonce: nonce,
          deviceId: deviceId,
          localDeviceId: localId,
          pairKey: key,
        );
      }

      final now = DateTime.now();
      expect(
        await evaluate('dddddddd-0000-0000-0000-000000000000', now),
        PingOutcome.unverified,
      );
      expect(
        await evaluate(deviceId, now.subtract(const Duration(seconds: 301))),
        PingOutcome.unverified,
      );
      expect(
        await evaluate(deviceId, now.subtract(const Duration(seconds: 240))),
        PingOutcome.alive,
      );
    });

    test('a 426 is upgradeRequired; a non-pong 200 is unverified', () async {
      expect(
        await ping((_) async => (426, jsonEncode(upgradeRequiredBody))),
        PingOutcome.upgradeRequired,
      );
      expect(
        await ping(
          (_) async => (200, jsonEncode({'deviceId': deviceId, 'v': 2})),
        ),
        PingOutcome.unverified,
      );
      expect(await ping((_) async => null), PingOutcome.unverified);
    });

    test(
      'the responder answers 426, 401, 400 stale and 409 replayed',
      () async {
        final guard = ReplayGuard();
        Future<int> respond(ClipEnvelope envelope) async {
          final (status, _) = await LivenessPing.respond(
            envelope: envelope,
            localDeviceId: deviceId,
            getKey: (id) async => id == localId ? key : null,
            replayGuard: guard,
          );
          return status;
        }

        final ping = await LivenessPing.sealPing(
          deviceId: deviceId,
          localDeviceId: localId,
          pairKey: key,
        );
        expect(
          await respond(
            ClipEnvelope(
              v: 1,
              sourceDeviceId: localId,
              nonce: ping.nonce,
              ciphertext: ping.ciphertext,
            ),
          ),
          426,
        );
        expect(
          await respond(
            await LivenessPing.sealPing(
              deviceId: deviceId,
              localDeviceId: 'eeeeeeee-0000-0000-0000-000000000000',
              pairKey: key,
            ),
          ),
          401,
        );
        expect(
          await respond(
            await CryptoEnvelopeUtils.sealJson(
              const {},
              purpose: EnvelopePurpose.clip,
              sourceDeviceId: localId,
              recipientDeviceId: deviceId,
              pairKey: key,
            ),
          ),
          401,
        );
        expect(
          await respond(
            await LivenessPing.sealPing(
              deviceId: deviceId,
              localDeviceId: localId,
              pairKey: key,
              sentAt: DateTime.now().subtract(const Duration(seconds: 301)),
            ),
          ),
          400,
        );
        expect(await respond(ping), 200);
        expect(await respond(ping), 409);
      },
    );
  });
}
