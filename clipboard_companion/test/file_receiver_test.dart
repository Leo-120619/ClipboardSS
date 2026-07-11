import 'dart:io';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/file_transfer_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'file_transfer_test_support.dart';

void main() {
  const peerId = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
  final key = SecretKey(List<int>.filled(32, 7));

  Future<(FileReceiver, Directory, MutableClock)> makeReceiver() async {
    final store = await makePairedStore(peerId, key);
    final destDir = makeTempDir('dest');
    final clock = MutableClock(DateTime(2026, 1, 1, 12));
    final receiver = FileReceiver(
      pairedStore: store,
      transfersDirectory: makeTempDir('transfers'),
      destinationProvider: () => destDir,
      now: clock.now,
    );
    return (receiver, destDir, clock);
  }

  final data = List<int>.generate(10, (i) => i);

  test('happy path reassembles the file and removes the temp file', () async {
    final (receiver, destDir, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );

    expect((await receiver.handleOffer(t.offer)).statusCode, 200);
    for (var i = 0; i < t.chunks.length; i++) {
      expect(
        (await receiver.handleChunk(t.transferId, i, t.chunks[i])).statusCode,
        200,
      );
    }
    final finish = await sealControl(
      FileFinishPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    expect((await receiver.handleFinish(finish)).statusCode, 200);

    expect(await File('${destDir.path}/file.bin').readAsBytes(), data);
  });

  test('out-of-order chunks still complete', () async {
    final (receiver, destDir, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    for (final i in [2, 0, 1]) {
      expect(
        (await receiver.handleChunk(t.transferId, i, t.chunks[i])).statusCode,
        200,
      );
    }
    final finish = await sealControl(
      FileFinishPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    expect((await receiver.handleFinish(finish)).statusCode, 200);
    expect(await File('${destDir.path}/file.bin').readAsBytes(), data);
  });

  test('duplicate chunk is idempotent', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    final second = await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    expect(second.statusCode, 200);
    expect(second.body['received'], 1);
  });

  test('a malformed duplicate chunk is authenticated and rejected', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: [1, 2, 3, 4],
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    expect(
      (await receiver.handleChunk(
        t.transferId,
        0,
        List<int>.filled(16, 0),
      )).statusCode,
      400,
    );
  });

  test('offer validation rejects unsafe ids and invalid math', () async {
    final (receiver, _, _) = await makeReceiver();
    Future<dynamic> offer(String id, int size, int chunkSize, int chunkCount) =>
        sealControl(
          FileOfferPayload(
            transferId: id,
            fileName: 'file.bin',
            fileSize: size,
            mimeType: 'application/octet-stream',
            fileHash: 'h',
            chunkSize: chunkSize,
            chunkCount: chunkCount,
            createdAt: DateTime.now(),
            sourceDeviceName: 'Peer',
          ).toJson(),
          peerId,
          key,
        );
    final invalidId = await receiver.handleOffer(
      await offer('../../evil', 1, 1, 1),
    );
    expect(invalidId.statusCode, 400);
    expect(statusOf(invalidId), 'invalidId');
    final invalidOffer = await receiver.handleOffer(
      await offer('00000000-0000-0000-0000-000000000000', 1, -1, 1),
    );
    expect(invalidOffer.statusCode, 400);
    expect(statusOf(invalidOffer), 'invalidOffer');
  });

  test('finish before all chunks returns 409 incomplete', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    final finish = await sealControl(
      FileFinishPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    final response = await receiver.handleFinish(finish);
    expect(response.statusCode, 409);
    expect(statusOf(response), 'incomplete');
  });

  test('corrupted chunk tears the session down with 400', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    final corrupt = List<int>.from(t.chunks[0]);
    corrupt[0] ^= 0xFF;
    expect(
      (await receiver.handleChunk(t.transferId, 0, corrupt)).statusCode,
      400,
    );
    expect(
      (await receiver.handleChunk(t.transferId, 1, t.chunks[1])).statusCode,
      404,
    );
  });

  test('hash mismatch returns 422 and deletes the temp file', () async {
    final (receiver, destDir, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
      overrideHash: '0' * 64,
    );
    await receiver.handleOffer(t.offer);
    for (var i = 0; i < t.chunks.length; i++) {
      await receiver.handleChunk(t.transferId, i, t.chunks[i]);
    }
    final finish = await sealControl(
      FileFinishPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    final response = await receiver.handleFinish(finish);
    expect(response.statusCode, 422);
    expect(statusOf(response), 'hashMismatch');
    expect(File('${destDir.path}/file.bin').existsSync(), isFalse);
  });

  test('cancel removes the session; later chunks get 410', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    final cancel = await sealControl(
      FileCancelPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    expect((await receiver.handleCancel(cancel)).statusCode, 200);
    expect(
      (await receiver.handleChunk(t.transferId, 1, t.chunks[1])).statusCode,
      410,
    );
  });

  test('idle sessions are garbage-collected', () async {
    final (receiver, _, clock) = await makeReceiver();
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    clock.advance(const Duration(seconds: 61));
    await receiver.garbageCollect();
    expect(
      (await receiver.handleChunk(t.transferId, 1, t.chunks[1])).statusCode,
      404,
    );
  });

  test('chunk for an unknown transfer returns 404', () async {
    final (receiver, _, _) = await makeReceiver();
    expect(
      (await receiver.handleChunk(
        'nope',
        0,
        List<int>.filled(32, 0),
      )).statusCode,
      404,
    );
  });

  test('offer from an unpaired device returns 401', () async {
    final (receiver, _, _) = await makeReceiver();
    final strangerKey = SecretKey(List<int>.filled(32, 9));
    final t = await prepareTransfer(
      data: data,
      chunkSize: 4,
      peerId: 'aaaaaaaa-0000-0000-0000-000000000000',
      key: strangerKey,
    );
    expect((await receiver.handleOffer(t.offer)).statusCode, 401);
  });

  test('a duplicate active transferId is rejected with 409', () async {
    final (receiver, _, _) = await makeReceiver();
    final t = await prepareTransfer(
      data: [1, 2, 3, 4],
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    expect((await receiver.handleOffer(t.offer)).statusCode, 200);
    expect((await receiver.handleOffer(t.offer)).statusCode, 409);
  });

  test('colliding file names get a unique suffix', () async {
    final (receiver, destDir, _) = await makeReceiver();
    File('${destDir.path}/file.bin').writeAsStringSync('existing');
    final t = await prepareTransfer(
      data: [1, 2, 3, 4],
      chunkSize: 4,
      peerId: peerId,
      key: key,
    );
    await receiver.handleOffer(t.offer);
    await receiver.handleChunk(t.transferId, 0, t.chunks[0]);
    final finish = await sealControl(
      FileFinishPayload(t.transferId).toJson(),
      peerId,
      key,
    );
    expect((await receiver.handleFinish(finish)).statusCode, 200);
    expect(await File('${destDir.path}/file (1).bin').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
  });
}
