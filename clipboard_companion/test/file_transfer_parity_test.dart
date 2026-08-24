import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipboard_companion/core/content_hasher.dart';
import 'package:clipboard_companion/core/file_transfer_crypto.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Pinned vectors — must match docs/wire-protocol.md byte-for-byte.
  final pairKey = SecretKey(List<int>.generate(32, (i) => i)); // 00..1f
  const transferId = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
  final sample = <int>[1, 2, 3];

  test('fileHash of [1,2,3] matches the pinned vector', () {
    expect(ContentHasher.fileHash(sample),
        '53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe');
  });

  test('deriveFileKey matches the pinned vector', () async {
    final fileKey = await FileTransferCrypto.deriveFileKey(pairKey, transferId);
    expect(hex(await fileKey.extractBytes()),
        '2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554');
  });

  test('chunk nonces are 4 zero bytes plus big-endian index', () {
    expect(hex(FileTransferCrypto.nonceForChunk(0)), '000000000000000000000000');
    expect(hex(FileTransferCrypto.nonceForChunk(1)), '000000000000000000000001');
  });

  test('sealed chunk bodies match the pinned vectors', () async {
    final fileKey = await FileTransferCrypto.deriveFileKey(pairKey, transferId);
    final chunk0 = await FileTransferCrypto.sealChunk(sample, fileKey, 0);
    final chunk1 = await FileTransferCrypto.sealChunk(sample, fileKey, 1);
    expect(hex(chunk0), '878b3fd3c6494ba0be8976ec7543362243af08');
    expect(hex(chunk1), 'fc5bf0de6da51d44d7e16d35ec05ed598dd1cf');
  });

  test('openChunk round-trips a sealed chunk', () async {
    final fileKey = await FileTransferCrypto.deriveFileKey(pairKey, transferId);
    final sealed = await FileTransferCrypto.sealChunk(sample, fileKey, 7);
    final opened = await FileTransferCrypto.openChunk(sealed, fileKey, 7);
    expect(opened, Uint8List.fromList(sample));
  });

  test('openChunk fails when the index (nonce) is wrong', () async {
    final fileKey = await FileTransferCrypto.deriveFileKey(pairKey, transferId);
    final sealed = await FileTransferCrypto.sealChunk(sample, fileKey, 0);
    expect(() => FileTransferCrypto.openChunk(sealed, fileKey, 1), throwsA(anything));
  });

  test('openChunk fails when the key is wrong', () async {
    final fileKey = await FileTransferCrypto.deriveFileKey(pairKey, transferId);
    final sealed = await FileTransferCrypto.sealChunk(sample, fileKey, 0);
    final otherKey = await FileTransferCrypto.deriveFileKey(
        pairKey, '00000000-0000-0000-0000-000000000000');
    expect(() => FileTransferCrypto.openChunk(sealed, otherKey, 0), throwsA(anything));
  });
}
