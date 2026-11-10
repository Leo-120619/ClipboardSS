import 'dart:async';

import 'package:clipboard_companion/core/clip_server.dart';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/file_transfer_models.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'file_transfer_test_support.dart';

const _cap = 20 * 1024 * 1024;
const _chunk = 64 * 1024;

/// A body stream of [total] bytes that records how many bytes were actually pulled.
class _CountingBody {
  final int total;
  int pulled = 0;
  _CountingBody(this.total);

  Stream<List<int>> stream() async* {
    while (pulled < total) {
      final size = (total - pulled) < _chunk ? total - pulled : _chunk;
      pulled += size;
      yield List<int>.filled(size, 0x41);
    }
  }
}

void main() {
  const peerId = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
  final key = SecretKey(List<int>.filled(32, 5));

  Future<Handler> makeHandler({bool withReceiver = false}) async {
    final store = await makePairedStore(peerId, key);
    final identity = DeviceIdentity(
      id: 'cccccccc-0000-0000-0000-000000000000',
      name: 'Companion',
    );
    return ClipServer(
      identity: identity,
      pairingCoordinator: PairingCoordinator(
        identity: identity,
        pairedStore: store,
      ),
      pairedStore: store,
      onClipReceived: (_) {},
      fileReceiver: withReceiver
          ? FileReceiver(
              pairedStore: store,
              transfersDirectory: makeTempDir('transfers'),
              destinationProvider: () => makeTempDir('dest'),
            )
          : null,
    ).buildHandler();
  }

  Uri uri(String path) => Uri.parse('http://localhost$path');

  test('oversizedBodyReturns413', () async {
    final handler = await makeHandler();
    final body = _CountingBody(21 * 1024 * 1024);

    final response = await handler(
      Request('POST', uri('/v1/clip'), body: body.stream()),
    );

    expect(response.statusCode, 413);
    // The handler stops reading once the running total passes the cap.
    expect(body.pulled, lessThanOrEqualTo(_cap + _chunk));
  });

  test(
    'oversized Content-Length is rejected before reading the body',
    () async {
      final handler = await makeHandler();
      final body = _CountingBody(21 * 1024 * 1024);

      final response = await handler(
        Request(
          'POST',
          uri('/v1/clip'),
          headers: {'content-length': '${21 * 1024 * 1024}'},
          body: body.stream(),
        ),
      );

      expect(response.statusCode, 413);
      expect(body.pulled, 0);
    },
  );

  for (final path in [
    '/v1/pair/start',
    '/v1/pair/confirm',
    '/v1/file/offer',
    '/v1/file/finish',
    '/v1/file/cancel',
  ]) {
    test('$path rejects an oversized body with 413', () async {
      final handler = await makeHandler(withReceiver: true);
      final body = _CountingBody(21 * 1024 * 1024);

      final response = await handler(
        Request('POST', uri(path), body: body.stream()),
      );

      expect(response.statusCode, 413);
      expect(body.pulled, lessThanOrEqualTo(_cap + _chunk));
    });
  }

  test('readBodyCapped returns the full body when under the cap', () async {
    final bytes = await readBodyCapped(
      Request('POST', uri('/v1/clip'), body: [1, 2, 3]),
    );
    expect(bytes, [1, 2, 3]);
  });

  test('readBodyCapped throws once the running total exceeds max', () async {
    final body = _CountingBody(FileTransferConstants.chunkSize * 2);
    await expectLater(
      readBodyCapped(
        Request('POST', uri('/v1/clip'), body: body.stream()),
        max: 1000,
      ),
      throwsA(isA<BodyTooLargeException>()),
    );
    expect(body.pulled, lessThanOrEqualTo(1000 + _chunk));
  });

  test('readBodyCapped rejects a declared Content-Length over max', () async {
    final body = _CountingBody(10);
    await expectLater(
      readBodyCapped(
        Request(
          'POST',
          uri('/v1/clip'),
          headers: {'content-length': '2000'},
          body: body.stream(),
        ),
        max: 1000,
      ),
      throwsA(isA<BodyTooLargeException>()),
    );
    expect(body.pulled, 0);
  });
}
