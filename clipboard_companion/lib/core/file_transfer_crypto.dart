import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'file_transfer_models.dart';

/// Per-transfer chunk crypto. Canonical spec: docs/wire-protocol.md.
///
/// ```
/// fileKey    = HKDF-SHA256(secret=pairKey, salt="ClipboardSS_FileKey",
///                          info=ASCII lowercase transferId, L=32)
/// chunkNonce = 0x00000000 || uint64_big_endian(chunkIndex)
/// chunkBody  = ChaCha20-Poly1305(fileKey, chunkNonce, plaintext) = ciphertext || tag
/// ```
class FileTransferCrypto {
  static final _chacha = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<SecretKey> deriveFileKey(SecretKey pairKey, String transferId) {
    // In package:cryptography's HKDF the `nonce` parameter is the salt (mirrors
    // PairingSession's pairKey derivation).
    return _hkdf.deriveKey(
      secretKey: pairKey,
      nonce: utf8.encode(FileTransferConstants.fileKeySalt),
      info: utf8.encode(transferId.toLowerCase()),
    );
  }

  /// 4 zero bytes followed by the big-endian 8-byte chunk index (12 bytes total).
  static Uint8List nonceForChunk(int index) {
    final bytes = Uint8List(12);
    ByteData.sublistView(bytes).setUint64(4, index, Endian.big);
    return bytes;
  }

  static Future<Uint8List> sealChunk(List<int> plaintext, SecretKey fileKey, int index) async {
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: fileKey,
      nonce: nonceForChunk(index),
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> openChunk(List<int> body, SecretKey fileKey, int index) async {
    if (body.length < 16) throw Exception('chunk too short');
    final ciphertext = body.sublist(0, body.length - 16);
    final mac = body.sublist(body.length - 16);
    final box = SecretBox(ciphertext, nonce: nonceForChunk(index), mac: Mac(mac));
    final plaintext = await _chacha.decrypt(box, secretKey: fileKey);
    return Uint8List.fromList(plaintext);
  }
}
