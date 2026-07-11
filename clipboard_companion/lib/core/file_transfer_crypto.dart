import 'dart:convert';
import 'dart:isolate';
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

  static Future<Uint8List> sealChunk(
    List<int> plaintext,
    SecretKey fileKey,
    int index,
  ) async {
    final keyBytes = await fileKey.extractBytes();
    return Isolate.run(() async {
      final box = await Chacha20.poly1305Aead().encrypt(
        plaintext,
        secretKey: SecretKeyData(keyBytes),
        nonce: nonceForChunk(index),
      );
      final result = Uint8List(box.cipherText.length + box.mac.bytes.length);
      result.setRange(0, box.cipherText.length, box.cipherText);
      result.setRange(box.cipherText.length, result.length, box.mac.bytes);
      return result;
    });
  }

  static Future<Uint8List> openChunk(
    List<int> body,
    SecretKey fileKey,
    int index,
  ) async {
    if (body.length < 16) throw Exception('chunk too short');
    final keyBytes = await fileKey.extractBytes();
    final bodyBytes = body is Uint8List ? body : Uint8List.fromList(body);
    return Isolate.run(() async {
      final ciphertext = Uint8List.sublistView(
        bodyBytes,
        0,
        bodyBytes.length - 16,
      );
      final mac = Uint8List.sublistView(bodyBytes, bodyBytes.length - 16);
      final box = SecretBox(
        ciphertext,
        nonce: nonceForChunk(index),
        mac: Mac(mac),
      );
      final plaintext = await Chacha20.poly1305Aead().decrypt(
        box,
        secretKey: SecretKeyData(keyBytes),
      );
      return Uint8List.fromList(plaintext);
    });
  }
}
