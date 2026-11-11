import 'dart:convert';

import 'models.dart';

/// Outcome of a freshness / replay check on an opened envelope.
enum ReplayCheck {
  ok,

  /// `|now - sentAt|` exceeds the freshness window: the clocks disagree, or the
  /// envelope is old. Receivers answer `400 {"status":"stale"}`.
  stale,

  /// The `(sourceDeviceId, nonce)` pair was already accepted within the retention
  /// period. Receivers answer `409 {"status":"replayed"}`.
  replayed,
}

/// HTTP status and JSON body for a failed [ReplayCheck], or null for [ReplayCheck.ok].
(int, Map<String, dynamic>)? replayRejection(ReplayCheck check) =>
    switch (check) {
      ReplayCheck.ok => null,
      ReplayCheck.stale => (400, {'status': 'stale'}),
      ReplayCheck.replayed => (409, {'status': 'replayed'}),
    };

/// Formats [time] the way every platform writes wire timestamps:
/// whole-second UTC, `yyyy-MM-ddTHH:mm:ssZ`.
String wireTimestamp(DateTime time) =>
    '${time.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// The authenticated `sentAt` of an opened inner payload. Missing or unparsable
/// values read as the epoch, which [ReplayGuard] rejects as stale.
DateTime sentAtOf(Map<String, dynamic> json) {
  final value = json['sentAt'];
  return (value is String ? DateTime.tryParse(value) : null) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

/// Rejects stale and replayed envelopes. Call [check] only after the AEAD open
/// succeeded (so `sentAt` is authenticated and junk never fills the set), and before
/// any side effect. One instance per receiver process, shared by every envelope
/// endpoint. Dart runs the server on a single isolate, so no locking is needed.
/// See docs/wire-protocol.md ("Freshness and replay protection").
class ReplayGuard {
  static const defaultWindow = Duration(seconds: 300);
  static const defaultRetention = Duration(seconds: 600);

  final Duration window;
  final Duration retention;
  final DateTime Function() _now;

  /// Accepted `(source, nonce)` keys and when they were accepted.
  final _seen = <String, DateTime>{};

  ReplayGuard({
    this.window = defaultWindow,
    this.retention = defaultRetention,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  ReplayCheck check({
    required String sourceDeviceId,
    required String nonce,
    required DateTime sentAt,
  }) {
    final current = _now();
    final cutoff = current.subtract(retention);
    _seen.removeWhere((_, acceptedAt) => acceptedAt.isBefore(cutoff));

    if (current.difference(sentAt).abs() > window) return ReplayCheck.stale;

    final key = _key(sourceDeviceId, nonce);
    if (_seen.containsKey(key)) return ReplayCheck.replayed;
    _seen[key] = current;
    return ReplayCheck.ok;
  }

  /// Keys on the decoded nonce bytes: Dart's decoder also accepts base64url, so an
  /// alternative spelling of the same nonce must not slip past the set.
  static String _key(String sourceDeviceId, String nonce) {
    String canonicalNonce;
    try {
      canonicalNonce = base64Encode(base64Decode(nonce));
    } on FormatException {
      canonicalNonce = nonce;
    }
    return '${canonicalDeviceId(sourceDeviceId)}|$canonicalNonce';
  }
}
