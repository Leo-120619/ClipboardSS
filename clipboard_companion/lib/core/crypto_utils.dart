import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'models.dart';

class PairingSession {
  late SimpleKeyPair _privateKey;
  late List<int> _ephemeralPublicKey;

  List<int> get ephemeralPublicKey => _ephemeralPublicKey;

  static final _x25519 = X25519();
  static final _hkdfPairKey = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _hkdfCodeKey = Hkdf(hmac: Hmac.sha256(), outputLength: 4);

  Future<void> init() async {
    _privateKey = await _x25519.newKeyPair();
    final pk = await _privateKey.extractPublicKey();
    _ephemeralPublicKey = pk.bytes;
  }

  Future<PairingResult> completePairing({
    required List<int> remotePublicKeyBytes,
    required String initiatorId,
    required String targetId,
    required bool isInitiator,
    required String code,
  }) async {
    final remotePublicKey = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: _privateKey,
      remotePublicKey: remotePublicKey,
    );
    final info = utf8.encode(code);

    final pairKey = await _hkdfPairKey.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('ClipboardSS_PairKey'),
      info: info,
    );

    final codeKey = await _hkdfCodeKey.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('ClipboardSS_ConfirmCode'),
      info: info,
    );

    final codeBytes = await codeKey.extractBytes();
    final byteData = ByteData.sublistView(Uint8List.fromList(codeBytes));
    final codeValue = byteData.getUint32(0, Endian.big);
    final confirmCode = (codeValue % 1000000).toString().padLeft(6, '0');

    return PairingResult(
      pairKey: pairKey,
      confirmCode: confirmCode,
    );
  }

  static Future<List<int>> generateConfirmationProof(SecretKey pairKey, String initiatorId, String targetId) async {
    final message = utf8.encode('confirm${canonicalDeviceId(initiatorId)}${canonicalDeviceId(targetId)}');
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(message, secretKey: pairKey);
    return mac.bytes;
  }

  static Future<bool> verifyConfirmationProof(List<int> proof, SecretKey pairKey, String initiatorId, String targetId) async {
    final expectedProof = await generateConfirmationProof(pairKey, initiatorId, targetId);
    if (proof.length != expectedProof.length) return false;
    for (int i = 0; i < proof.length; i++) {
      if (proof[i] != expectedProof[i]) return false;
    }
    return true;
  }
}

class PairingResult {
  final SecretKey pairKey;
  final String confirmCode;

  PairingResult({
    required this.pairKey,
    required this.confirmCode,
  });
}

class CryptoEnvelopeUtils {
  static final _chacha = Chacha20.poly1305Aead();

  static Future<ClipEnvelope> seal(ClipPayload payload, String sourceDeviceId, SecretKey pairKey) async {
    final plaintext = utf8.encode(jsonEncode(payload.toJson()));
    final secretBox = await _chacha.encrypt(
      plaintext,
      secretKey: pairKey,
    );

    // Combine ciphertext and mac(tag) as per Swift implementation
    final combinedCiphertext = Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);

    return ClipEnvelope(
      v: 1,
      sourceDeviceId: canonicalDeviceId(sourceDeviceId),
      nonce: base64Encode(secretBox.nonce),
      ciphertext: base64Encode(combinedCiphertext),
    );
  }

  static Future<ClipPayload> open(ClipEnvelope envelope, SecretKey pairKey) async {
    final nonce = base64Decode(envelope.nonce);
    final combinedData = base64Decode(envelope.ciphertext);
    if (combinedData.length < 16) throw Exception('Invalid ciphertext length');

    final ciphertext = combinedData.sublist(0, combinedData.length - 16);
    final macBytes = combinedData.sublist(combinedData.length - 16);

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final plaintext = await _chacha.decrypt(
      secretBox,
      secretKey: pairKey,
    );

    final jsonStr = utf8.decode(plaintext);
    return ClipPayload.fromJson(jsonDecode(jsonStr));
  }

  /// Seals an arbitrary JSON map into an envelope — used by the file-transfer control
  /// messages (offer / finish / cancel). Same construction as [seal].
  static Future<ClipEnvelope> sealJson(
      Map<String, dynamic> json, String sourceDeviceId, SecretKey pairKey) async {
    final plaintext = utf8.encode(jsonEncode(json));
    final secretBox = await _chacha.encrypt(plaintext, secretKey: pairKey);
    final combinedCiphertext =
        Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);
    return ClipEnvelope(
      v: 1,
      sourceDeviceId: sourceDeviceId,
      nonce: base64Encode(secretBox.nonce),
      ciphertext: base64Encode(combinedCiphertext),
    );
  }

  /// Opens an envelope into an arbitrary JSON map.
  static Future<Map<String, dynamic>> openJson(ClipEnvelope envelope, SecretKey pairKey) async {
    final nonce = base64Decode(envelope.nonce);
    final combinedData = base64Decode(envelope.ciphertext);
    if (combinedData.length < 16) throw Exception('Invalid ciphertext length');
    final ciphertext = combinedData.sublist(0, combinedData.length - 16);
    final macBytes = combinedData.sublist(combinedData.length - 16);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes));
    final plaintext = await _chacha.decrypt(secretBox, secretKey: pairKey);
    return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
  }
}
