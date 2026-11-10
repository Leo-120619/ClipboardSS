import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'models.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';

/// Result of a `/v1/pair/reveal` request on the hosting (target) side.
enum PairRevealOutcome {
  /// 200: the commitment opened; both screens now show the number.
  ok,

  /// 401: no active code, or no matching initiator waiting to reveal.
  rejected,

  /// 400: the revealed key or salt does not open the commitment.
  invalid,
}

/// Result of a `/v1/pair/confirm` request on the hosting (target) side.
enum PairConfirmOutcome {
  paired,
  rejected,
  alreadyPaired,

  /// 408: this device's user did not confirm the number in time.
  timedOut,
}

/// The number both screens show during pairing, with the other device's name.
class PairingComparison {
  /// The other device.
  final String deviceName;
  final String confirmCode;

  /// This device's user already pressed Confirm and is waiting for the other side.
  final bool localConfirmed;

  const PairingComparison({
    required this.deviceName,
    required this.confirmCode,
    this.localConfirmed = false,
  });

  PairingComparison confirmedLocally() => PairingComparison(
    deviceName: deviceName,
    confirmCode: confirmCode,
    localConfirmed: true,
  );
}

/// Thrown by [PairingCoordinator.handlePairStart] when the start must be refused
/// with 403: no active code, another initiator is pending, or a bad commitment.
class PairingRejectedException implements Exception {
  final String reason;
  PairingRejectedException(this.reason);
  @override
  String toString() => 'PairingRejectedException: $reason';
}

/// Thrown by [PairingCoordinator.confirmPairing] when the target answers 409:
/// it already has this device paired and the user must remove it there first.
class PairingAlreadyPairedException implements Exception {
  @override
  String toString() => 'PairingAlreadyPairedException';
}

/// The other device refused (403 / 401 / 400): wrong code, numbers not
/// confirmed there, or cancelled.
class PairingNotAcceptedException implements Exception {
  final int statusCode;
  PairingNotAcceptedException(this.statusCode);
  @override
  String toString() => 'PairingNotAcceptedException: $statusCode';
}

/// The other device's user did not confirm the number within 60 s (408).
class PairingTimedOutException implements Exception {
  @override
  String toString() => 'PairingTimedOutException';
}

enum _HostDecision { confirmed, cancelled, timedOut }

class PairingCoordinator {
  /// How long the target holds `/v1/pair/confirm` waiting for its own user (else 408).
  static const defaultConfirmHoldTimeout = Duration(seconds: 60);

  /// Client timeout for `/v1/pair/confirm`: longer than the target's hold.
  static const defaultConfirmRequestTimeout = Duration(seconds: 75);

  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;
  final Duration confirmRequestTimeout;
  final Duration confirmHoldTimeout;
  final DateTime Function() _now;

  /// Called whenever the pairing state shown to the user changes: the hosted
  /// code ends (spent by any failure, expired, stopped), or a number to compare
  /// (as target or initiator) appears, changes or goes away.
  void Function()? onHostingChanged;

  PairingCoordinator({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
    this.confirmRequestTimeout = defaultConfirmRequestTimeout,
    this.confirmHoldTimeout = defaultConfirmHoldTimeout,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _now = clock ?? DateTime.now;

  // Hosting state. All pairing rules on the target side are enforced in
  // [handlePairStart] / [handlePairReveal] / [handlePairConfirmRequest]:
  // - one pending initiator per code (the same deviceId may restart until it
  //   has revealed; any other start is refused with 403);
  // - reveal and confirm are refused (401) unless the code is active and unexpired;
  // - any failure (bad reveal or commitment, bad proof, cancel here, 60 s confirm
  //   timeout) ends the code and clears pending state; so do stop, expiry and start;
  // - every confirm spends the code; an already paired deviceId gets 409;
  // - keys are stored only after both users confirmed the number;
  // - commitment and proof checks are constant-time; codes, numbers and keys are never logged.
  _PendingInitiator? _pending;
  _HeldConfirm? _held;
  String? _hostCode;
  DateTime? _hostCodeExpiry;
  Timer? _expiryTimer;
  PairingComparison? _hostComparison;

  /// Bumped whenever hosting ends or restarts, so an awaited handler can tell
  /// whether the state it read is still current.
  int _generation = 0;

  // Initiator state: the one device the user chose, waiting for the user to compare numbers.
  _PendingJoin? _pendingJoin;
  PairingComparison? _joinComparison;

  String? get hostCode => _activeHostCode();

  /// The number to compare while this device is the target.
  PairingComparison? get hostComparison => _hostComparison;

  /// The number to compare while this device is the initiator.
  PairingComparison? get joinComparison => _joinComparison;

  /// True while a `/v1/pair/confirm` is waiting for this device's user.
  @visibleForTesting
  bool get isHoldingConfirm => _held != null;

  // Target

  String startHosting({Duration ttl = const Duration(seconds: 180)}) {
    _endHosting(notify: false);
    final code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
    _hostCode = code;
    _hostCodeExpiry = _now().add(ttl);
    // Clears the code from the UI when it expires, without waiting for a request.
    _expiryTimer = Timer(ttl, () => _activeHostCode());
    onHostingChanged?.call();
    return code;
  }

  void stopHosting() => _endHosting();

  /// This device's user confirmed the number shown in [hostComparison].
  void confirmHostedPairing() {
    final held = _held;
    if (held != null) {
      _resolveHeld(held, _HostDecision.confirmed);
    } else if (_hostComparison != null) {
      _hostComparison = _hostComparison!.confirmedLocally();
      onHostingChanged?.call();
    }
  }

  /// This device's user cancelled (or the numbers differ): the code is spent.
  void cancelHostedPairing() => _endHosting();

  /// Ends the hosted code and all pending state; a held confirm is answered 401.
  void _endHosting({bool notify = true}) {
    _generation++;
    _pending = null;
    _hostCode = null;
    _hostCodeExpiry = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _hostComparison = null;
    final held = _held;
    if (held != null) _resolveHeld(held, _HostDecision.cancelled);
    if (notify) onHostingChanged?.call();
  }

  void _resolveHeld(_HeldConfirm held, _HostDecision decision) {
    _held = null;
    held.timeout.cancel();
    if (!held.completer.isCompleted) held.completer.complete(decision);
  }

  /// The hosted code while it is unexpired; an expired code ends hosting.
  String? _activeHostCode() {
    final code = _hostCode;
    if (code == null) return null;
    final expiry = _hostCodeExpiry;
    if (expiry == null || !expiry.isAfter(_now())) {
      _endHosting();
      return null;
    }
    return code;
  }

  // Called when this device is the target of a pairing request.
  Future<String> handlePairStart(
    String initiatorId,
    String initiatorName,
    String commitmentBase64,
    String remoteHost,
  ) async {
    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    _ensureCanStart(canonicalInitiatorId);
    final List<int> commitment;
    try {
      commitment = base64Decode(commitmentBase64);
    } on FormatException {
      throw PairingRejectedException('malformed commitment');
    }
    if (commitment.length != 32) {
      throw PairingRejectedException('malformed commitment');
    }

    final generation = _generation;
    final session = PairingSession();
    await session.init();

    // Hosting state may have changed while the key pair was generated.
    if (generation != _generation) {
      throw PairingRejectedException('not hosting');
    }
    _ensureCanStart(canonicalInitiatorId);
    _pending = _PendingInitiator(
      id: canonicalInitiatorId,
      name: initiatorName,
      host: remoteHost.isEmpty ? null : remoteHost,
      commitment: commitment,
      session: session,
    );
    return base64Encode(session.ephemeralPublicKey);
  }

  void _ensureCanStart(String initiatorId) {
    if (_activeHostCode() == null) {
      throw PairingRejectedException('not hosting');
    }
    final pending = _pending;
    if (pending != null &&
        (pending.id != initiatorId || pending.pairKey != null)) {
      throw PairingRejectedException('another initiator is pending');
    }
  }

  // Called when this device is the target and the initiator reveals its key.
  Future<PairRevealOutcome> handlePairReveal(
    String initiatorId,
    String initiatorPubKeyBase64,
    String saltBase64,
  ) async {
    final code = _activeHostCode();
    if (code == null) return PairRevealOutcome.rejected;
    final pending = _pending;
    if (pending == null ||
        pending.id != canonicalDeviceId(initiatorId) ||
        pending.pairKey != null) {
      _endHosting();
      return PairRevealOutcome.rejected;
    }

    final generation = _generation;
    PairingResult? result;
    try {
      final publicKey = base64Decode(initiatorPubKeyBase64);
      final salt = base64Decode(saltBase64);
      if (salt.length == PairingSession.saltLength &&
          await PairingSession.commitmentMatches(
            pending.commitment,
            publicKey,
            salt,
          )) {
        result = await pending.session.completePairing(
          remotePublicKeyBytes: publicKey,
          isInitiator: false,
          code: code,
        );
      }
    } on FormatException {
      result = null;
    } on ArgumentError {
      result = null;
    }

    // Hosting may have ended or restarted while the commitment was checked.
    if (generation != _generation || !identical(_pending, pending)) {
      return PairRevealOutcome.rejected;
    }
    if (result == null) {
      _endHosting();
      return PairRevealOutcome.invalid;
    }
    pending.pairKey = result.pairKey;
    _hostComparison = PairingComparison(
      deviceName: pending.name,
      confirmCode: result.confirmCode,
    );
    onHostingChanged?.call();
    return PairRevealOutcome.ok;
  }

  // Called when this device is the target and the initiator confirms the proof.
  Future<PairConfirmOutcome> handlePairConfirmRequest(
    String initiatorId,
    String proofBase64,
  ) async {
    if (_activeHostCode() == null) return PairConfirmOutcome.rejected;
    // Every confirm spends the code; the comparison stays on screen until it
    // is resolved. Taking the pending initiator before any await keeps
    // concurrent confirms from racing.
    final pending = _pending;
    final localConfirmed = _hostComparison?.localConfirmed ?? false;
    _pending = null;
    _hostCode = null;
    _hostCodeExpiry = null;
    _expiryTimer?.cancel();
    final generation = _generation;

    final canonicalInitiatorId = canonicalDeviceId(initiatorId);
    final pairKey = pending?.pairKey;
    var isValid = false;
    if (pending != null &&
        pending.id == canonicalInitiatorId &&
        pairKey != null) {
      try {
        isValid = await PairingSession.verifyConfirmationProof(
          base64Decode(proofBase64),
          pairKey,
          canonicalInitiatorId,
          identity.id,
        );
      } on FormatException {
        isValid = false;
      }
    }
    if (generation != _generation) return PairConfirmOutcome.rejected;
    if (!isValid || pending == null || pairKey == null) {
      _endHosting();
      return PairConfirmOutcome.rejected;
    }

    if (pairedStore.devices.any((d) => d.id == canonicalInitiatorId)) {
      _endHosting();
      return PairConfirmOutcome.alreadyPaired;
    }

    if (!localConfirmed) {
      final completer = Completer<_HostDecision>();
      _held = _HeldConfirm(
        completer,
        Timer(confirmHoldTimeout, () {
          final current = _held;
          if (current != null && identical(current.completer, completer)) {
            _resolveHeld(current, _HostDecision.timedOut);
          }
        }),
      );
      onHostingChanged?.call();
      final decision = await completer.future;
      if (decision != _HostDecision.confirmed) {
        _endHosting();
        return decision == _HostDecision.timedOut
            ? PairConfirmOutcome.timedOut
            : PairConfirmOutcome.rejected;
      }
    }
    _endHosting();

    await pairedStore.addDevice(
      PairedDevice(
        id: canonicalInitiatorId,
        name: pending.name,
        host: pending.host,
      ),
      pairKey,
    );
    return PairConfirmOutcome.paired;
  }

  // Initiator

  /// Runs `/v1/pair/start` and `/v1/pair/reveal` against the one device the
  /// user chose and returns the number to compare. Nothing is stored until
  /// [confirmPairing] succeeds.
  Future<PairingComparison> startPairing(Peer peer, String code) async {
    cancelPairing();
    final session = PairingSession();
    await session.init();
    final salt = PairingSession.randomSalt();

    final startResponse = await _post(peer, '/v1/pair/start', {
      'deviceId': identity.id,
      'deviceName': identity.name,
      'commitment': base64Encode(
        await PairingSession.commitment(session.ephemeralPublicKey, salt),
      ),
    }, requestTimeout);
    if (startResponse.statusCode != 200) {
      throw PairingNotAcceptedException(startResponse.statusCode);
    }

    final respJson = jsonDecode(startResponse.body);
    final targetId = canonicalDeviceId(respJson['deviceId'] as String);
    final targetName = respJson['deviceName'] as String;
    final targetPubKey = base64Decode(respJson['ephemeralPublicKey'] as String);

    final revealResponse = await _post(peer, '/v1/pair/reveal', {
      'deviceId': identity.id,
      'ephemeralPublicKey': base64Encode(session.ephemeralPublicKey),
      'salt': base64Encode(salt),
    }, requestTimeout);
    if (revealResponse.statusCode != 200) {
      throw PairingNotAcceptedException(revealResponse.statusCode);
    }

    final result = await session.completePairing(
      remotePublicKeyBytes: targetPubKey,
      isInitiator: true,
      code: code,
    );
    _pendingJoin = _PendingJoin(
      peer: peer,
      targetId: targetId,
      targetName: targetName,
      pairKey: result.pairKey,
    );
    final comparison = PairingComparison(
      deviceName: targetName,
      confirmCode: result.confirmCode,
    );
    _joinComparison = comparison;
    onHostingChanged?.call();
    return comparison;
  }

  /// This device's user confirmed the number: sends the proof and, once the
  /// other device's user confirmed too (200), stores the pairing.
  Future<void> confirmPairing() async {
    final join = _pendingJoin;
    if (join == null) {
      throw StateError('No pairing is waiting for confirmation');
    }
    _joinComparison = _joinComparison?.confirmedLocally();
    onHostingChanged?.call();
    try {
      final proof = await PairingSession.generateConfirmationProof(
        join.pairKey,
        identity.id,
        join.targetId,
      );
      final response = await _post(join.peer, '/v1/pair/confirm', {
        'deviceId': identity.id,
        'proof': base64Encode(proof),
      }, confirmRequestTimeout);

      switch (response.statusCode) {
        case 200:
          await pairedStore.addDevice(
            PairedDevice(
              id: join.targetId,
              name: join.targetName,
              host: join.peer.host,
            ),
            join.pairKey,
          );
        case 409:
          throw PairingAlreadyPairedException();
        case 408:
          throw PairingTimedOutException();
        default:
          throw PairingNotAcceptedException(response.statusCode);
      }
    } finally {
      if (identical(_pendingJoin, join)) {
        _pendingJoin = null;
        _joinComparison = null;
        onHostingChanged?.call();
      }
    }
  }

  /// This device's user cancelled (or the numbers differ). Nothing was stored.
  void cancelPairing() {
    if (_pendingJoin == null && _joinComparison == null) return;
    _pendingJoin = null;
    _joinComparison = null;
    onHostingChanged?.call();
  }

  Future<http.Response> _post(
    Peer peer,
    String path,
    Map<String, dynamic> body,
    Duration timeout,
  ) => _client
      .post(
        Uri.parse('http://${peer.host}:${peer.port}$path'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(timeout);
}

/// The single initiator that has sent `/v1/pair/start` against the hosted code.
class _PendingInitiator {
  final String id;
  final String name;
  final String? host;
  final List<int> commitment;
  final PairingSession session;

  /// Set by a valid `/v1/pair/reveal`.
  SecretKey? pairKey;

  _PendingInitiator({
    required this.id,
    required this.name,
    required this.host,
    required this.commitment,
    required this.session,
  });
}

/// A valid `/v1/pair/confirm` waiting for this device's user.
class _HeldConfirm {
  final Completer<_HostDecision> completer;
  final Timer timeout;
  _HeldConfirm(this.completer, this.timeout);
}

class _PendingJoin {
  final Peer peer;
  final String targetId;
  final String targetName;
  final SecretKey pairKey;

  _PendingJoin({
    required this.peer,
    required this.targetId,
    required this.targetName,
    required this.pairKey,
  });
}
