import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'models.dart';
import 'replay_guard.dart';

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
    final remotePublicKey = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );
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

    return PairingResult(pairKey: pairKey, confirmCode: confirmCode);
  }

  static Future<List<int>> generateConfirmationProof(
    SecretKey pairKey,
    String initiatorId,
    String targetId,
  ) async {
    final message = utf8.encode(
      'confirm${canonicalDeviceId(initiatorId)}${canonicalDeviceId(targetId)}',
    );
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(message, secretKey: pairKey);
    return mac.bytes;
  }

  static Future<bool> verifyConfirmationProof(
    List<int> proof,
    SecretKey pairKey,
    String initiatorId,
    String targetId,
  ) async {
    final expectedProof = await generateConfirmationProof(
      pairKey,
      initiatorId,
      targetId,
    );
    // Constant-time: inspect every byte regardless of where a mismatch occurs.
    if (proof.length != expectedProof.length) return false;
    var diff = 0;
    for (int i = 0; i < proof.length; i++) {
      diff |= proof[i] ^ expectedProof[i];
    }
    return diff == 0;
  }
}

class PairingResult {
  final SecretKey pairKey;
  final String confirmCode;

  PairingResult({required this.pairKey, required this.confirmCode});
}

/// What an envelope is for. Bound into the AEAD associated data so an envelope sealed
/// for one endpoint cannot be replayed against another.
enum EnvelopePurpose {
  clip('clip'),
  fileOffer('file-offer'),
  fileFinish('file-finish'),
  fileCancel('file-cancel'),
  ping('ping'),
  pong('pong');

  const EnvelopePurpose(this.wire);

  /// Value used in the associated data.
  final String wire;
}

/// The envelope's `v` is not [wireProtocolVersion]; servers answer 426.
class UnsupportedEnvelopeVersionException implements Exception {
  final int version;
  const UnsupportedEnvelopeVersionException(this.version);

  @override
  String toString() => 'Unsupported envelope version $version';
}

/// Wire envelope v2: ChaCha20-Poly1305 over the inner JSON with associated data
/// `ClipboardSS/2|<purpose>|<source lowercase>|<recipient lowercase>`, binding sender,
/// recipient and purpose. See docs/wire-protocol.md.
class CryptoEnvelopeUtils {
  static final _chacha = Chacha20.poly1305Aead();

  static List<int> associatedData(
    EnvelopePurpose purpose,
    String sourceDeviceId,
    String recipientDeviceId,
  ) => utf8.encode(
    'ClipboardSS/$wireProtocolVersion|${purpose.wire}|'
    '${canonicalDeviceId(sourceDeviceId)}|${canonicalDeviceId(recipientDeviceId)}',
  );

  static Future<ClipEnvelope> seal(
    ClipPayload payload, {
    required EnvelopePurpose purpose,
    required String sourceDeviceId,
    required String recipientDeviceId,
    required SecretKey pairKey,
    DateTime? sentAt,
  }) => sealJson(
    payload.toJson(),
    purpose: purpose,
    sourceDeviceId: sourceDeviceId,
    recipientDeviceId: recipientDeviceId,
    pairKey: pairKey,
    sentAt: sentAt,
  );

  static Future<ClipPayload> open(
    ClipEnvelope envelope, {
    required EnvelopePurpose purpose,
    required String recipientDeviceId,
    required SecretKey pairKey,
  }) async => ClipPayload.fromJson(
    await openJson(
      envelope,
      purpose: purpose,
      recipientDeviceId: recipientDeviceId,
      pairKey: pairKey,
    ),
  );

  /// Seals an arbitrary JSON map (file-transfer control messages use this directly),
  /// stamping `sentAt` (default: now) into the inner JSON so the receiver's
  /// [ReplayGuard] checks freshness on an authenticated value.
  static Future<ClipEnvelope> sealJson(
    Map<String, dynamic> json, {
    required EnvelopePurpose purpose,
    required String sourceDeviceId,
    required String recipientDeviceId,
    required SecretKey pairKey,
    DateTime? sentAt,
  }) => sealBytes(
    utf8.encode(
      jsonEncode({...json, 'sentAt': wireTimestamp(sentAt ?? DateTime.now())}),
    ),
    purpose: purpose,
    sourceDeviceId: sourceDeviceId,
    recipientDeviceId: recipientDeviceId,
    pairKey: pairKey,
  );

  /// Seals raw inner bytes. [nonce] is injectable only so the pinned vector can be
  /// reproduced; production callers leave it null (random).
  @visibleForTesting
  static Future<ClipEnvelope> sealBytes(
    List<int> plaintext, {
    required EnvelopePurpose purpose,
    required String sourceDeviceId,
    required String recipientDeviceId,
    required SecretKey pairKey,
    List<int>? nonce,
  }) async {
    final secretBox = await _chacha.encrypt(
      plaintext,
      secretKey: pairKey,
      nonce: nonce,
      aad: associatedData(purpose, sourceDeviceId, recipientDeviceId),
    );
    return ClipEnvelope(
      v: wireProtocolVersion,
      sourceDeviceId: canonicalDeviceId(sourceDeviceId),
      nonce: base64Encode(secretBox.nonce),
      ciphertext: base64Encode([
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]),
    );
  }

  /// Opens an envelope addressed to [recipientDeviceId] (the local device) for [purpose].
  static Future<Map<String, dynamic>> openJson(
    ClipEnvelope envelope, {
    required EnvelopePurpose purpose,
    required String recipientDeviceId,
    required SecretKey pairKey,
  }) async {
    final plaintext = await openBytes(
      envelope,
      purpose: purpose,
      recipientDeviceId: recipientDeviceId,
      pairKey: pairKey,
    );
    return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
  }

  static Future<List<int>> openBytes(
    ClipEnvelope envelope, {
    required EnvelopePurpose purpose,
    required String recipientDeviceId,
    required SecretKey pairKey,
  }) async {
    if (envelope.v != wireProtocolVersion) {
      throw UnsupportedEnvelopeVersionException(envelope.v);
    }
    final nonce = base64Decode(envelope.nonce);
    final combinedData = base64Decode(envelope.ciphertext);
    if (nonce.length != 12 || combinedData.length < 16) {
      throw Exception('Invalid envelope nonce or ciphertext');
    }
    final ciphertext = combinedData.sublist(0, combinedData.length - 16);
    final macBytes = combinedData.sublist(combinedData.length - 16);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes));
    return _chacha.decrypt(
      secretBox,
      secretKey: pairKey,
      aad: associatedData(purpose, envelope.sourceDeviceId, recipientDeviceId),
    );
  }
}
