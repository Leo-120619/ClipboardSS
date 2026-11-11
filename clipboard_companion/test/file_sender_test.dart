import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:clipboard_companion/core/content_hasher.dart';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/file_sender.dart';
import 'package:clipboard_companion/core/file_transfer_models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/replay_guard.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'file_transfer_test_support.dart';

void main() {
  const peerId = '550e8400-e29b-41d4-a716-446655440000';
  final key = SecretKey(List<int>.filled(32, 3));
  final peer = Peer(id: peerId, name: 'Peer', host: '10.0.0.1', port: 51888);

  File makeFile(int bytes) {
    final file = File('${makeTempDir('src').path}/payload.bin');
    file.writeAsBytesSync(List<int>.generate(bytes, (i) => i % 251));
    return file;
  }

  Future<FileSender> makeSender(http.Client client) async {
    final store = await makePairedStore(peerId, key);
    return FileSender(
      identity: DeviceIdentity(
        id: 'aaaaaaaa-1111-2222-3333-444444444444',
        name: 'Mac',
      ),
      pairedStore: store,
      client: client,
    );
  }

  test('emits offer, chunks, then finish with correct chunk headers', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    final sender = await makeSender(client);
    final file = makeFile(9 * 1024 * 1024); // 3 chunks

    await sender.sendFile(file: file, peer: peer);

    final paths = requests.map((r) => r.url.path).toList();
    expect(paths, [
      '/v1/file/offer',
      '/v1/file/chunk',
      '/v1/file/chunk',
      '/v1/file/chunk',
      '/v1/file/finish',
    ]);
    final chunkReqs = requests
        .where((r) => r.url.path == '/v1/file/chunk')
        .toList();
    expect(chunkReqs.map((r) => r.headers['x-chunk-index']), ['0', '1', '2']);
    expect(chunkReqs.map((r) => r.headers['x-transfer-id']).toSet().length, 1);
    expect(
      chunkReqs.every(
        (r) => r.headers['content-type'] == 'application/octet-stream',
      ),
      isTrue,
    );
  });

  test('progress is monotonic and ends at 1.0', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final sender = await makeSender(client);
    final file = makeFile(9 * 1024 * 1024);
    final values = <double>[];

    await sender.sendFile(file: file, peer: peer, onProgress: values.add);

    final sorted = [...values]..sort();
    expect(values, sorted);
    expect(values.last, 1.0);
  });

  test('cancellation mid-stream aborts and issues /v1/file/cancel', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    final sender = await makeSender(client);
    final file = makeFile(9 * 1024 * 1024);
    var polls = 0;

    await expectLater(
      sender.sendFile(file: file, peer: peer, isCancelled: () => ++polls > 1),
      throwsA(isA<FileSendCancelledException>()),
    );
    expect(requests.last.url.path, '/v1/file/cancel');
  });

  test('a non-200 chunk response aborts and issues cancel', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        '{}',
        request.url.path == '/v1/file/chunk' ? 500 : 200,
      );
    });
    final sender = await makeSender(client);
    final file = makeFile(1024);

    await expectLater(
      sender.sendFile(file: file, peer: peer),
      throwsA(isA<FileSendException>()),
    );
    expect(requests.map((r) => r.url.path), contains('/v1/file/cancel'));
  });

  test('a non-200 offer aborts before any chunk or cancel', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        '{}',
        request.url.path == '/v1/file/offer' ? 401 : 200,
      );
    });
    final sender = await makeSender(client);
    final file = makeFile(1024);

    await expectLater(
      sender.sendFile(file: file, peer: peer),
      throwsA(isA<FileSendException>()),
    );
    expect(requests.map((r) => r.url.path), ['/v1/file/offer']);
  });

  test('refuses to send to a peer that advertises an older protocol', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    final sender = await makeSender(client);
    final outdated = Peer(
      id: peerId,
      name: 'Peer',
      host: '10.0.0.1',
      port: 51888,
      protocolVersion: 1,
    );

    await expectLater(
      sender.sendFile(file: makeFile(16), peer: outdated),
      throwsA(isA<FileSendNeedsUpdateException>()),
    );
    expect(requests, isEmpty);
  });

  test('a 426 answer surfaces as needs-update, not unauthorized', () async {
    final client = MockClient(
      (request) async =>
          http.Response('{"status":"upgradeRequired","minVersion":2}', 426),
    );
    final sender = await makeSender(client);

    await expectLater(
      sender.sendFile(file: makeFile(16), peer: peer),
      throwsA(
        isA<FileSendNeedsUpdateException>().having(
          (e) => e.toString(),
          'message',
          updateOtherDeviceMessage,
        ),
      ),
    );
  });

  test(
    'a stale answer surfaces as clock out of sync with the device',
    () async {
      final client = MockClient(
        (request) async => http.Response('{"status":"stale"}', 400),
      );
      final sender = await makeSender(client);

      await expectLater(
        sender.sendFile(file: makeFile(16), peer: peer),
        throwsA(
          isA<FileSendClockOutOfSyncException>().having(
            (e) => e.toString(),
            'message',
            'Clock out of sync with Peer.',
          ),
        ),
      );
    },
  );

  test('sending to an unpaired peer throws', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final sender = await makeSender(client);
    final stranger = Peer(
      id: 'bbbbbbbb-0000-0000-0000-000000000000',
      name: 'X',
      host: '10.0.0.9',
      port: 51888,
    );
    final file = makeFile(16);

    await expectLater(
      sender.sendFile(file: file, peer: stranger),
      throwsA(isA<FileSendException>()),
    );
  });

  test('a stalled request fails within the configured timeout', () async {
    final client = MockClient((request) => Completer<http.Response>().future);
    final store = await makePairedStore(peerId, key);
    final sender = FileSender(
      identity: DeviceIdentity(
        id: 'aaaaaaaa-1111-2222-3333-444444444444',
        name: 'Mac',
      ),
      pairedStore: store,
      client: client,
      requestTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      sender.sendFile(file: makeFile(16), peer: peer),
      throwsA(isA<FileSendException>()),
    );
  });

  group('finish timeout', () {
    FileSender timedSender(
      http.Client client,
      PairedDeviceStore store, {
      Duration Function(int fileSize)? finishTimeout,
    }) => FileSender(
      identity: DeviceIdentity(
        id: 'aaaaaaaa-1111-2222-3333-444444444444',
        name: 'Mac',
      ),
      pairedStore: store,
      client: client,
      requestTimeout: const Duration(milliseconds: 50),
      finishTimeout: finishTimeout,
    );

    test('finishUsesExtendedTimeoutForLargeFile', () async {
      expect(
        FileTransferConstants.finishTimeout(4 * 1024 * 1024 * 1024),
        const Duration(seconds: 205),
      );
      expect(
        FileTransferConstants.finishTimeout(0),
        const Duration(seconds: 30),
      );
      expect(
        FileTransferConstants.finishTimeout(30 * 20 * 1024 * 1024 + 1),
        const Duration(seconds: 31),
      );
      expect(
        FileTransferConstants.finishTimeout(1 << 40),
        const Duration(seconds: 600),
      );

      // The receiver hashes before answering finish: longer than the
      // per-request timeout is fine.
      final client = MockClient((request) async {
        if (request.url.path == '/v1/file/finish') {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return http.Response('{}', 200);
      });
      final sender = timedSender(client, await makePairedStore(peerId, key));

      expect(
        await sender.sendFile(file: makeFile(1024), peer: peer),
        FileSendOutcome.delivered,
      );
    });

    test('senderDoesNotCancelAfterFinishTimeout', () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/v1/file/finish') {
          return Completer<http.Response>().future;
        }
        return http.Response('{}', 200);
      });
      final sender = timedSender(
        client,
        await makePairedStore(peerId, key),
        finishTimeout: (_) => const Duration(milliseconds: 20),
      );

      // A saved file must not be reported failed or deleted (Review Focus 4).
      expect(
        await sender.sendFile(file: makeFile(1024), peer: peer),
        FileSendOutcome.unconfirmed,
      );
      expect(requests, ['/v1/file/offer', '/v1/file/chunk', '/v1/file/finish']);
    });
  });

  test(
    'loopback e2e: file arrives hash-verified through the real routes',
    () async {
      final store = await makePairedStore(peerId, key);
      final destDir = makeTempDir('dest');
      final receiver = FileReceiver(
        pairedStore: store,
        // One shared store: the receiver is the `peer` the sender addresses.
        localDeviceId: peer.id,
        transfersDirectory: makeTempDir('transfers'),
        destinationProvider: () => destDir,
      );

      // MockClient that dispatches straight into the real FileReceiver.
      final client = MockClient((request) async {
        FileTransferResponse result;
        switch (request.url.path) {
          case '/v1/file/offer':
            result = await receiver.handleOffer(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
            break;
          case '/v1/file/chunk':
            result = await receiver.handleChunk(
              request.headers['x-transfer-id'] ?? '',
              int.tryParse(request.headers['x-chunk-index'] ?? '') ?? -1,
              request.bodyBytes,
            );
            break;
          case '/v1/file/finish':
            result = await receiver.handleFinish(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
            break;
          case '/v1/file/cancel':
            result = await receiver.handleCancel(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
            break;
          default:
            result = FileTransferResponse(404, {});
        }
        return http.Response(jsonEncode(result.body), result.statusCode);
      });

      final sender = FileSender(
        // Sender identity == paired peer id so the receiver can find the key.
        identity: DeviceIdentity(id: peerId, name: 'Peer'),
        pairedStore: store,
        client: client,
      );
      final file = File('${makeTempDir('src').path}/big.bin');
      final data = List<int>.generate(
        10 * 1024 * 1024 + 123,
        (i) => (i * 31 + 7) % 256,
      );
      file.writeAsBytesSync(data);

      await sender.sendFile(file: file, peer: peer);

      final dest = File('${destDir.path}/big.bin');
      expect(
        await ContentHasher.fileHashOfFile(dest),
        ContentHasher.fileHash(data),
      );
    },
  );

  group('clock skew (Review Focus 1)', () {
    Future<Directory> loopbackSend(Duration receiverClockOffset) async {
      final store = await makePairedStore(peerId, key);
      final destDir = makeTempDir('dest');
      final receiver = FileReceiver(
        pairedStore: store,
        localDeviceId: peer.id,
        transfersDirectory: makeTempDir('transfers'),
        destinationProvider: () => destDir,
        replayGuard: ReplayGuard(
          now: () => DateTime.now().add(receiverClockOffset),
        ),
      );
      final client = MockClient((request) async {
        final FileTransferResponse result;
        switch (request.url.path) {
          case '/v1/file/offer':
            result = await receiver.handleOffer(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
          case '/v1/file/chunk':
            result = await receiver.handleChunk(
              request.headers['x-transfer-id'] ?? '',
              int.tryParse(request.headers['x-chunk-index'] ?? '') ?? -1,
              request.bodyBytes,
            );
          case '/v1/file/finish':
            result = await receiver.handleFinish(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
          case '/v1/file/cancel':
            result = await receiver.handleCancel(
              ClipEnvelope.fromJson(jsonDecode(request.body)),
            );
          default:
            result = FileTransferResponse(404, {});
        }
        return http.Response(jsonEncode(result.body), result.statusCode);
      });
      final sender = FileSender(
        identity: DeviceIdentity(id: peerId, name: 'Peer'),
        pairedStore: store,
        client: client,
      );
      await sender.sendFile(file: makeFile(100), peer: peer);
      return destDir;
    }

    test('a receiver 4 minutes off still receives the file', () async {
      final destDir = await loopbackSend(const Duration(minutes: 4));
      expect(File('${destDir.path}/payload.bin').existsSync(), isTrue);
    });

    test('a receiver 20 minutes off reports clock out of sync', () async {
      await expectLater(
        loopbackSend(const Duration(minutes: -20)),
        throwsA(isA<FileSendClockOutOfSyncException>()),
      );
    });
  });
}
