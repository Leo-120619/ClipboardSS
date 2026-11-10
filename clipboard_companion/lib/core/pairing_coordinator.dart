import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';

/// Result of a `/v1/pair/confirm` request on the hosting (target) side.
enum PairConfirmOutcome { paired, rejected, alreadyPaired }

/// Thrown by [PairingCoordinator.handlePairStart] when the start must be refused
/// with 403: no active code, or another initiator is already pending.
class PairingRejectedException implements Exception {
  final String reason;
  PairingRejectedException(this.reason);
  @override
  String toString() => 'PairingRejectedException: $reason';
}

/// Thrown by [PairingCoordinator.startPairing] when the target answers 409:
/// it already has this device paired and the user must remove it there first.
class PairingAlreadyPairedException implements Exception {
  @override
  String toString() => 'PairingAlreadyPairedException';
}

class PairingCoordinator {
  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;
  final DateTime Function() _now;

  PairingCoordinator({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _now = clock ?? DateTime.now;

  // Hosting state. All pairing rules on the target side are enforced in
  // [handlePairStart] / [handlePairConfirmRequest] below: one pending
  // initiator per code, confirm only while the code is active, any confirm
  // ends the code, and no silent re-pair of a known deviceId.
  _PendingInitiator? _pending;
  String? _hostCode;
  DateTime? _hostCodeExpiry;

  String? get hostCode => _activeHostCode();

  String startHosting({Duration ttl = const Duration(seconds: 180)}) {
    final code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
    _pending = null;
    _hostCode = code;
    _hostCodeExpiry = _now().add(ttl);
    return code;
  }

  void stopHosting() {
    _pending = null;
    _hostCode = null;
    _hostCodeExpiry = null;
  }

  /// The hosted code while it is unexpired; an expired code is cleared
  /// together with any pending initiator.
  String? _activeHostCode() {
    final code = _hostCode;
    final expiry = _hostCodeExpiry;
    if (code == null || expiry == null || !expiry.isAfter(_now())) {
      stopHosting();
      return null;
    }
    return code;
  }

  void _ensureCanStart(String code, String initiatorId) {
    if (_activeHostCode() != code) {
      throw PairingRejectedException('not hosting');
    }
    final pending = _pending;
    if (pending != null && pending.id != initiatorId) {
      throw PairingRejectedException('another initiator is pending');
    }
  }

  // Called when this device is the target of a pairing request
  Future<String> handlePairStart(
    String initiatorId,
    String initiatorName,
    String initiatorPubKeyBase64,
    String remoteHost,
  ) async {
    final code = _activeHostCode();
    if (code == null) {
      throw PairingRejectedException('not hosting');
    }
    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    _ensureCanStart(code, canonicalInitiatorId);

    final session = PairingSession();
    await session.init();
    final result = await session.completePairing(
      remotePublicKeyBytes: base64Decode(initiatorPubKeyBase64),
      initiatorId: canonicalInitiatorId,
      targetId: identity.id,
      isInitiator: false,
      code: code,
    );

    // Hosting state may have changed while the key exchange was awaited.
    _ensureCanStart(code, canonicalInitiatorId);
    _pending = _PendingInitiator(
      id: canonicalInitiatorId,
      name: initiatorName,
      host: remoteHost.isEmpty ? null : remoteHost,
      pairKey: result.pairKey,
    );
    return base64Encode(session.ephemeralPublicKey);
  }

  // Called when this device is the target and the initiator confirms the proof
  Future<PairConfirmOutcome> handlePairConfirmRequest(
    String initiatorId,
    String proofBase64,
  ) async {
    // Every confirm ends the hosted code, whatever its outcome. Taking the
    // pending initiator before any await keeps concurrent confirms from racing.
    final codeIsActive = _activeHostCode() != null;
    final pending = _pending;
    stopHosting();

    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    if (!codeIsActive ||
        pending == null ||
        pending.id != canonicalInitiatorId) {
      return PairConfirmOutcome.rejected;
    }

    final List<int> proof;
    try {
      proof = base64Decode(proofBase64);
    } on FormatException {
      return PairConfirmOutcome.rejected;
    }
    final isValid = await PairingSession.verifyConfirmationProof(
      proof,
      pending.pairKey,
      canonicalInitiatorId,
      identity.id,
    );
    if (!isValid) return PairConfirmOutcome.rejected;

    if (pairedStore.devices.any((d) => d.id == canonicalInitiatorId)) {
      return PairConfirmOutcome.alreadyPaired;
    }

    await pairedStore.addDevice(
      PairedDevice(
        id: canonicalInitiatorId,
        name: pending.name,
        host: pending.host,
      ),
      pending.pairKey,
    );
    return PairConfirmOutcome.paired;
  }

  // Called when this device initiates a pairing request
  Future<String> startPairing(Peer peer, String code) async {
    final session = PairingSession();
    await session.init();

    final reqData = jsonEncode({
      'deviceId': identity.id,
      'deviceName': identity.name,
      'ephemeralPublicKey': base64Encode(session.ephemeralPublicKey),
    });

    final uri = Uri.parse('http://${peer.host}:${peer.port}/v1/pair/start');
    final response = await _client
        .post(uri, headers: {'Content-Type': 'application/json'}, body: reqData)
        .timeout(requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Pair start failed: ${response.statusCode}');
    }

    final respJson = jsonDecode(response.body);
    final targetId = canonicalDeviceId(respJson['deviceId'] as String);
    final targetName = respJson['deviceName'] as String;
    final targetPubKeyBase64 = respJson['ephemeralPublicKey'] as String;

    final result = await session.completePairing(
      remotePublicKeyBytes: base64Decode(targetPubKeyBase64),
      initiatorId: identity.id,
      targetId: targetId,
      isInitiator: true,
      code: code,
    );

    final proof = await PairingSession.generateConfirmationProof(
      result.pairKey,
      identity.id,
      targetId,
    );

    final confirmReqData = jsonEncode({
      'deviceId': identity.id,
      'proof': base64Encode(proof),
    });

    final confirmUri = Uri.parse(
      'http://${peer.host}:${peer.port}/v1/pair/confirm',
    );
    final confirmResponse = await _client
        .post(
          confirmUri,
          headers: {'Content-Type': 'application/json'},
          body: confirmReqData,
        )
        .timeout(requestTimeout);

    if (confirmResponse.statusCode == 200) {
      await pairedStore.addDevice(
        PairedDevice(id: targetId, name: targetName, host: peer.host),
        result.pairKey,
      );
      return result.confirmCode;
    } else if (confirmResponse.statusCode == 409) {
      throw PairingAlreadyPairedException();
    } else {
      throw Exception('Pair confirm failed: ${confirmResponse.statusCode}');
    }
  }
}

/// The single initiator that has completed `/v1/pair/start` against the hosted code.
class _PendingInitiator {
  final String id;
  final String name;
  final String? host;
  final SecretKey pairKey;

  _PendingInitiator({
    required this.id,
    required this.name,
    required this.host,
    required this.pairKey,
  });
}
