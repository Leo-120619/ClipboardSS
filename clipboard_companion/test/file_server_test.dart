import 'dart:convert';
import 'dart:io';

import 'package:clipboard_companion/core/clip_server.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:clipboard_companion/core/replay_guard.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'file_transfer_test_support.dart';

void main() {
  test(
    'port conflicts are reported without raw socket implementation text',
    () {
      final message = ClipServer.startErrorMessage(
        const SocketException(
          'The shared flag to bind() needs to be true when binding port 51888',
        ),
      );

      expect(message, 'Sync port 51888 is already in use.');
    },
  );

  const peerId = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
  final key = SecretKey(List<int>.filled(32, 5));

  Future<ClipServer> makeServer({required bool withReceiver}) async {
    final store = await makePairedStore(peerId, key);
    final identity = DeviceIdentity(
      id: 'cccccccc-0000-0000-0000-000000000000',
      name: 'Companion',
    );
    FileReceiver? receiver;
    if (withReceiver) {
      receiver = FileReceiver(
        pairedStore: store,
        localDeviceId: identity.id,
        transfersDirectory: makeTempDir('transfers'),
        destinationProvider: () => makeTempDir('dest'),
      );
    }
    return ClipServer(
      identity: identity,
      pairingCoordinator: PairingCoordinator(
        identity: identity,
        pairedStore: store,
      ),
      pairedStore: store,
      onClipReceived: (_) {},
      fileReceiver: receiver,
    );
  }

  Uri uri(String path) => Uri.parse('http://localhost$path');

  test('file routes 404 when no FileReceiver is wired', () async {
    final handler = (await makeServer(withReceiver: false)).buildHandler();
    final response = await handler(
      Request(
        'POST',
        uri('/v1/file/chunk'),
        headers: {'x-transfer-id': 't', 'x-chunk-index': '0'},
        body: <int>[0],
      ),
    );
    expect(response.statusCode, 404);
  });

  test('offer route accepts a sealed envelope and returns ready', () async {
    final server = await makeServer(withReceiver: true);
    final handler = server.buildHandler();
    final t = await prepareTransfer(
      data: [1, 2, 3, 4],
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );

    final response = await handler(
      Request(
        'POST',
        uri('/v1/file/offer'),
        body:
            '{"v":${t.offer.v},"sourceDeviceId":"${t.offer.sourceDeviceId}",'
            '"nonce":"${t.offer.nonce}","ciphertext":"${t.offer.ciphertext}"}',
      ),
    );
    expect(response.statusCode, 200);
    expect(await response.readAsString(), contains('ready'));
  });

  test('chunk route parses headers and stores the chunk', () async {
    final server = await makeServer(withReceiver: true);
    final handler = server.buildHandler();
    final t = await prepareTransfer(
      data: [1, 2, 3, 4],
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );

    await handler(
      Request(
        'POST',
        uri('/v1/file/offer'),
        body:
            '{"v":${t.offer.v},"sourceDeviceId":"${t.offer.sourceDeviceId}",'
            '"nonce":"${t.offer.nonce}","ciphertext":"${t.offer.ciphertext}"}',
      ),
    );

    final response = await handler(
      Request(
        'POST',
        uri('/v1/file/chunk'),
        headers: {'X-Transfer-Id': t.transferId, 'X-Chunk-Index': '0'},
        body: t.chunks[0],
      ),
    );
    expect(response.statusCode, 200);
  });

  test('chunk route returns 404 for an unknown transfer', () async {
    final server = await makeServer(withReceiver: true);
    final handler = server.buildHandler();
    final response = await handler(
      Request(
        'POST',
        uri('/v1/file/chunk'),
        headers: {'x-transfer-id': 'nope', 'x-chunk-index': '0'},
        body: List<int>.filled(32, 0),
      ),
    );
    expect(response.statusCode, 404);
  });

  for (final path in [
    '/v1/clip',
    '/v1/file/offer',
    '/v1/file/finish',
    '/v1/file/cancel',
  ]) {
    test('v1EnvelopeGetsUpgradeRequired on $path', () async {
      final handler = (await makeServer(withReceiver: true)).buildHandler();
      // A real v1 envelope from a paired peer: it must not be reported as unauthorized.
      final response = await handler(
        Request(
          'POST',
          uri(path),
          body:
              '{"v":1,"sourceDeviceId":"$peerId",'
              '"nonce":"AAAAAAAAAAAAAAAB","ciphertext":"AAAAAAAAAAAAAAAAAAAAAA=="}',
        ),
      );
      expect(response.statusCode, 426);
      expect(jsonDecode(await response.readAsString()), {
        'status': 'upgradeRequired',
        'minVersion': 2,
      });
    });
  }

  group('clip replay protection', () {
    Future<(Handler, List<ClipPayload>)> makeClipServer() async {
      final store = await makePairedStore(peerId, key);
      final identity = DeviceIdentity(id: receiverId, name: 'Companion');
      final received = <ClipPayload>[];
      final server = ClipServer(
        identity: identity,
        pairingCoordinator: PairingCoordinator(
          identity: identity,
          pairedStore: store,
        ),
        pairedStore: store,
        onClipReceived: received.add,
      );
      return (server.buildHandler(), received);
    }

    Future<String> clipBody(String text, {DateTime? sentAt}) async {
      final envelope = await CryptoEnvelopeUtils.seal(
        ClipPayload(
          id: 'clip-$text',
          type: ClipType.text,
          createdAt: DateTime.now(),
          text: text,
          contentHash: 'hash-$text',
          sourceDeviceName: 'Mac',
        ),
        purpose: EnvelopePurpose.clip,
        sourceDeviceId: peerId,
        recipientDeviceId: receiverId,
        pairKey: key,
        sentAt: sentAt,
      );
      return jsonEncode(envelope.toJson());
    }

    test('replayedClipDoesNotTouchPasteboard', () async {
      final (handler, received) = await makeClipServer();
      final body = await clipBody('secret');

      final first = await handler(Request('POST', uri('/v1/clip'), body: body));
      expect(first.statusCode, 200);
      expect(received, hasLength(1));

      final replayed = await handler(
        Request('POST', uri('/v1/clip'), body: body),
      );
      expect(replayed.statusCode, 409);
      expect(jsonDecode(await replayed.readAsString())['status'], 'replayed');
      expect(received, hasLength(1));
    });

    test('a clip sent 20 minutes ago is stale; 4 minutes ago syncs', () async {
      final (handler, received) = await makeClipServer();
      final stale = await handler(
        Request(
          'POST',
          uri('/v1/clip'),
          body: await clipBody(
            'old',
            sentAt: DateTime.now().subtract(const Duration(minutes: 20)),
          ),
        ),
      );
      expect(stale.statusCode, 400);
      expect(jsonDecode(await stale.readAsString())['status'], 'stale');
      expect(received, isEmpty);

      final skewed = await handler(
        Request(
          'POST',
          uri('/v1/clip'),
          body: await clipBody(
            'skewed',
            sentAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
        ),
      );
      expect(skewed.statusCode, 200);
      expect(received, hasLength(1));
    });

    test('clip and file endpoints share one guard per server', () async {
      final store = await makePairedStore(peerId, key);
      final identity = DeviceIdentity(id: receiverId, name: 'Companion');
      final guard = ReplayGuard();
      final receiver = FileReceiver(
        pairedStore: store,
        localDeviceId: identity.id,
        transfersDirectory: makeTempDir('transfers'),
        destinationProvider: () => makeTempDir('dest'),
        replayGuard: guard,
      );
      final server = ClipServer(
        identity: identity,
        pairingCoordinator: PairingCoordinator(
          identity: identity,
          pairedStore: store,
        ),
        pairedStore: store,
        onClipReceived: (_) {},
        fileReceiver: receiver,
        replayGuard: guard,
      );
      expect(identical(server.replayGuard, receiver.replayGuard), isTrue);
    });
  });
}
