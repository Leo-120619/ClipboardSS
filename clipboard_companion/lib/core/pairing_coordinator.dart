import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';

class PairingCoordinator {
  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;

  PairingCoordinator({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final Map<String, PairingSession> _pendingTargetSessions = {};
  final Map<String, PairingResult> _targetTempResults = {};
  final Map<String, String> _targetDeviceNames = {};
  final Map<String, String> _targetHosts = {};

  String? _hostCode;
  DateTime? _hostCodeExpiry;

  String? get hostCode => _activeHostCode();

  String startHosting({Duration ttl = const Duration(seconds: 180)}) {
    final code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
    _hostCode = code;
    _hostCodeExpiry = DateTime.now().add(ttl);
    return code;
  }

  void stopHosting() {
    _hostCode = null;
    _hostCodeExpiry = null;
  }

  String? _activeHostCode() {
    final code = _hostCode;
    final expiry = _hostCodeExpiry;
    if (code == null || expiry == null || expiry.isBefore(DateTime.now())) {
      stopHosting();
      return null;
    }
    return code;
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
      throw Exception('Not hosting');
    }

    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    final session = PairingSession();
    await session.init();
    _pendingTargetSessions[canonicalInitiatorId] = session;
    _targetDeviceNames[canonicalInitiatorId] = initiatorName;
    if (remoteHost.isNotEmpty) {
      _targetHosts[canonicalInitiatorId] = remoteHost;
    }

    final result = await session.completePairing(
      remotePublicKeyBytes: base64Decode(initiatorPubKeyBase64),
      initiatorId: canonicalInitiatorId,
      targetId: identity.id,
      isInitiator: false,
      code: code,
    );

    _targetTempResults[canonicalInitiatorId] = result;
    return base64Encode(session.ephemeralPublicKey);
  }

  // Called when this device is the target and the initiator confirms the proof
  Future<bool> handlePairConfirmRequest(
    String initiatorId,
    String proofBase64,
  ) async {
    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    final result = _targetTempResults[canonicalInitiatorId];
    if (result == null) return false;

    final proof = base64Decode(proofBase64);
    final isValid = await PairingSession.verifyConfirmationProof(
      proof,
      result.pairKey,
      canonicalInitiatorId,
      identity.id,
    );

    if (isValid) {
      await pairedStore.addDevice(
        PairedDevice(
          id: canonicalInitiatorId,
          name: _targetDeviceNames[canonicalInitiatorId] ?? 'Device',
          host: _targetHosts[canonicalInitiatorId],
        ),
        result.pairKey,
      );
      stopHosting();
      _targetTempResults.remove(canonicalInitiatorId);
      _pendingTargetSessions.remove(canonicalInitiatorId);
      _targetDeviceNames.remove(canonicalInitiatorId);
      _targetHosts.remove(canonicalInitiatorId);
    }
    return isValid;
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
    } else {
      throw Exception('Pair confirm failed: ${confirmResponse.statusCode}');
    }
  }
}
