import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'crypto_utils.dart';
import 'models.dart';
import 'replay_guard.dart';

/// What one `POST /v1/ping` to one host proved. See docs/wire-protocol.md
/// ("Liveness Ping").
enum PingOutcome {
  /// A valid pong from the expected device: it is online at the pinged host and
  /// speaks v2.
  alive,

  /// The host answered 426 (or 404, a v1 server without the ping route): it speaks
  /// another protocol version.
  upgradeRequired,

  /// The host answered `400 {"status":"stale"}`: its clock disagrees with ours by
  /// more than the freshness window. Unauthenticated, so it never proves liveness.
  clockSkew,

  /// No evidence either way: unreachable, or an answer that is not a valid, fresh
  /// pong from the expected device for this ping.
  unverified,
}

/// Authenticated liveness: the only evidence that a paired device is online at a host.
class LivenessPing {
  static const path = '/v1/ping';

  /// Seals a ping for [deviceId]. The returned envelope's nonce is what the pong
  /// must echo.
  static Future<ClipEnvelope> sealPing({
    required String deviceId,
    required String localDeviceId,
    required SecretKey pairKey,
    DateTime? sentAt,
  }) => CryptoEnvelopeUtils.sealJson(
    const {},
    purpose: EnvelopePurpose.ping,
    sourceDeviceId: localDeviceId,
    recipientDeviceId: deviceId,
    pairKey: pairKey,
    sentAt: sentAt,
  );

  /// Pings [deviceId] through [post], which sends the JSON body to `/v1/ping` on the
  /// host being tested and returns `(statusCode, body)`, or null when the host did not
  /// answer.
  static Future<PingOutcome> ping({
    required String deviceId,
    required String localDeviceId,
    required SecretKey pairKey,
    required Future<(int, String)?> Function(String body) post,
    DateTime Function()? now,
  }) async {
    try {
      final envelope = await sealPing(
        deviceId: deviceId,
        localDeviceId: localDeviceId,
        pairKey: pairKey,
        sentAt: now?.call(),
      );
      final response = await post(jsonEncode(envelope.toJson()));
      if (response == null) return PingOutcome.unverified;
      final (status, body) = response;
      return evaluatePong(
        statusCode: status,
        body: body,
        pingNonce: envelope.nonce,
        deviceId: deviceId,
        localDeviceId: localDeviceId,
        pairKey: pairKey,
        now: now?.call(),
      );
    } catch (_) {
      return PingOutcome.unverified;
    }
  }

  /// Caller-side validation: 200, a v2 `pong` envelope from [deviceId] sealed to us,
  /// fresh within the replay window, echoing this ping's nonce.
  static Future<PingOutcome> evaluatePong({
    required int statusCode,
    required String body,
    required String pingNonce,
    required String deviceId,
    required String localDeviceId,
    required SecretKey pairKey,
    DateTime? now,
  }) async {
    // 404: a v1 server has no ping route, so it is an older protocol, not "offline".
    if (statusCode == 426 || statusCode == 404) {
      return PingOutcome.upgradeRequired;
    }
    if (statusCode == 400 && _status(body) == 'stale') {
      return PingOutcome.clockSkew;
    }
    if (statusCode != 200) return PingOutcome.unverified;
    try {
      final envelope = ClipEnvelope.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
      if (envelope.sourceDeviceId != canonicalDeviceId(deviceId)) {
        return PingOutcome.unverified;
      }
      final json = await CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.pong,
        recipientDeviceId: localDeviceId,
        pairKey: pairKey,
      );
      final skew = (now ?? DateTime.now()).difference(sentAtOf(json)).abs();
      if (skew > ReplayGuard.defaultWindow) return PingOutcome.unverified;
      final echoed = json['pingNonce'];
      if (echoed is! String ||
          !_sameBytes(base64Decode(echoed), base64Decode(pingNonce))) {
        return PingOutcome.unverified;
      }
      return PingOutcome.alive;
    } catch (_) {
      return PingOutcome.unverified;
    }
  }

  /// Responder side of `POST /v1/ping`: version → pairing → AEAD open → replay guard →
  /// pong sealed back to the caller, as `(statusCode, json body)`. The local pause
  /// switch is not consulted: liveness reports reachability, and pausing only refuses
  /// content.
  static Future<(int, Map<String, dynamic>)> respond({
    required ClipEnvelope envelope,
    required String localDeviceId,
    required Future<SecretKey?> Function(String deviceId) getKey,
    required ReplayGuard replayGuard,
  }) async {
    if (envelope.v != wireProtocolVersion) {
      return (
        426,
        {'status': 'upgradeRequired', 'minVersion': wireProtocolVersion},
      );
    }
    final key = await getKey(envelope.sourceDeviceId);
    if (key == null) return (401, {'status': 'unauthorized'});
    final Map<String, dynamic> json;
    try {
      json = await CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.ping,
        recipientDeviceId: localDeviceId,
        pairKey: key,
      );
    } catch (_) {
      return (401, {'status': 'unauthorized'});
    }
    final rejection = replayRejection(
      replayGuard.check(
        sourceDeviceId: envelope.sourceDeviceId,
        nonce: envelope.nonce,
        sentAt: sentAtOf(json),
      ),
    );
    if (rejection != null) return rejection;
    final pong = await CryptoEnvelopeUtils.sealJson(
      {'pingNonce': envelope.nonce},
      purpose: EnvelopePurpose.pong,
      sourceDeviceId: localDeviceId,
      recipientDeviceId: envelope.sourceDeviceId,
      pairKey: key,
    );
    return (200, pong.toJson());
  }

  static String? _status(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic> && json['status'] is String
          ? json['status'] as String
          : null;
    } catch (_) {
      return null;
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
