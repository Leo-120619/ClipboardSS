import 'dart:convert';

import 'package:clipboard_companion/core/clip_server.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'fake_pair_key_storage.dart';

const _targetId = '4d967c79-47dc-4e1f-a3bd-d3160b082da7';
const _initiatorA = '550e8400-e29b-41d4-a716-446655440000';
const _initiatorB = '6fa459ea-ee8a-3ca4-894e-db77e160355e';

class _Initiation {
  final List<int> pairKey;
  final String proofBase64;
  _Initiation(this.pairKey, this.proofBase64);
}

class _Started {
  final PairingSession session;
  final List<int> salt;
  final String targetPublicKeyBase64;
  _Started(this.session, this.salt, this.targetPublicKeyBase64);
}

/// Separate preferences per store, so a target and an initiator in one test do
/// not share a paired-device list.
class _MemoryPrefs implements SharedPreferences {
  final Map<String, Object> _values = {};

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async => _values.remove(key) != null;

  @override
  Set<String> getKeys() => _values.keys.toSet();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<PairedDeviceStore> _newStore() async =>
    PairedDeviceStore(_MemoryPrefs(), keyStorage: FakePairKeyStorage());

class _Harness {
  final PairedDeviceStore pairedStore;
  final PairingCoordinator coordinator;
  int hostingChanges = 0;
  DateTime now = DateTime.utc(2027, 1, 15, 12);

  _Harness._(this.pairedStore, this.coordinator);

  static Future<_Harness> create({
    String id = _targetId,
    String name = 'Phone',
    http.Client? client,
    Duration confirmHoldTimeout = PairingCoordinator.defaultConfirmHoldTimeout,
    PairedDeviceStore? store,
  }) async {
    final pairedStore = store ?? await _newStore();
    late _Harness harness;
    final coordinator = PairingCoordinator(
      identity: DeviceIdentity(id: id, name: name),
      pairedStore: pairedStore,
      client: client,
      confirmHoldTimeout: confirmHoldTimeout,
      clock: () => harness.now,
    );
    harness = _Harness._(pairedStore, coordinator);
    coordinator.onHostingChanged = () => harness.hostingChanges++;
    return harness;
  }

  /// Plays the initiator side of `/v1/pair/start` only: a commitment to a fresh key.
  Future<_Started> startWithoutReveal(String initiatorId) async {
    final session = PairingSession();
    await session.init();
    final salt = PairingSession.randomSalt();
    final targetPublicKey = await coordinator.handlePairStart(
      initiatorId,
      'Initiator',
      base64Encode(
        await PairingSession.commitment(session.ephemeralPublicKey, salt),
      ),
      '10.0.0.9',
    );
    return _Started(session, salt, targetPublicKey);
  }

  /// Plays `/v1/pair/start` and `/v1/pair/reveal`, and derives the proof the
  /// initiator would send to `/v1/pair/confirm`.
  Future<_Initiation> start(String initiatorId, String code) async {
    final started = await startWithoutReveal(initiatorId);
    final reveal = await coordinator.handlePairReveal(
      initiatorId,
      base64Encode(started.session.ephemeralPublicKey),
      base64Encode(started.salt),
    );
    if (reveal != PairRevealOutcome.ok) {
      throw PairingRejectedException('reveal $reveal');
    }
    final result = await started.session.completePairing(
      remotePublicKeyBytes: base64Decode(started.targetPublicKeyBase64),
      isInitiator: true,
      code: code,
    );
    final proof = await PairingSession.generateConfirmationProof(
      result.pairKey,
      initiatorId,
      _targetId,
    );
    return _Initiation(
      await result.pairKey.extractBytes(),
      base64Encode(proof),
    );
  }

  Future<List<int>?> storedKey(String deviceId) async =>
      (await pairedStore.getKey(deviceId))?.extractBytes();

  /// Waits until a `/v1/pair/confirm` is waiting for this device's user.
  Future<void> waitUntilConfirmIsHeld() async {
    for (var i = 0; i < 500 && !coordinator.isHoldingConfirm; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(coordinator.isHoldingConfirm, isTrue);
  }
}

/// Routes the initiator's HTTP client into the target's real [ClipServer] handler,
/// recording every request.
class _Loopback {
  final List<Uri> requests = [];
  late final MockClient client;

  _Loopback(_Harness target) {
    final handler = ClipServer(
      identity: target.coordinator.identity,
      pairingCoordinator: target.coordinator,
      pairedStore: target.pairedStore,
      onClipReceived: (_) {},
    ).buildHandler();
    client = MockClient((request) async {
      requests.add(request.url);
      final response = await handler(
        shelf.Request(
          request.method,
          request.url,
          body: request.bodyBytes,
          headers: request.headers,
        ),
      );
      return http.Response(
        await response.readAsString(),
        response.statusCode,
        headers: response.headers,
      );
    });
  }
}

Future<(_Harness, _Harness, _Loopback)> _pair() async {
  final target = await _Harness.create(store: await _newStore());
  final loopback = _Loopback(target);
  final initiator = await _Harness.create(
    id: _initiatorA,
    name: 'Laptop',
    client: loopback.client,
    store: await _newStore(),
  );
  return (target, initiator, loopback);
}

final _targetPeer = Peer(
  id: _targetId,
  name: 'Phone',
  host: '10.0.0.2',
  port: 51888,
);

void main() {
  test('confirmWithWrongProofInvalidatesCode', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    final initiation = await h.start(_initiatorA, code);

    final wrong = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      base64Encode(List<int>.filled(32, 0)),
    );
    expect(wrong, PairConfirmOutcome.rejected);
    expect(h.coordinator.hostCode, isNull);
    expect(h.coordinator.hostComparison, isNull);

    // The correct proof no longer works, and a fresh start is refused: the user must generate a new code.
    final retry = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );
    expect(retry, PairConfirmOutcome.rejected);
    await expectLater(
      h.start(_initiatorA, code),
      throwsA(isA<PairingRejectedException>()),
    );
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('confirmAfterCodeExpiryIsRejected', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting(ttl: const Duration(seconds: 180));
    final initiation = await h.start(_initiatorA, code);
    h.coordinator.confirmHostedPairing();

    h.now = h.now.add(const Duration(seconds: 181));
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('confirmAfterStopHostingIsRejected', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    final initiation = await h.start(_initiatorA, code);

    h.coordinator.stopHosting();
    expect(h.coordinator.hostComparison, isNull);
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('secondInitiatorWhilePendingEndsCode', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    final first = await h.start(_initiatorA, code);

    await expectLater(
      h.startWithoutReveal(_initiatorB),
      throwsA(isA<PairingRejectedException>()),
    );
    expect(h.coordinator.hostCode, isNull);
    expect(h.coordinator.hostComparison, isNull);

    h.coordinator.confirmHostedPairing();
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      first.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('secondStartFromSameInitiatorEndsCode', () async {
    final h = await _Harness.create();
    h.coordinator.startHosting();
    final started = await h.startWithoutReveal(_initiatorA);

    await expectLater(
      h.startWithoutReveal(_initiatorA),
      throwsA(isA<PairingRejectedException>()),
    );
    expect(h.coordinator.hostCode, isNull);
    final reveal = await h.coordinator.handlePairReveal(
      _initiatorA,
      base64Encode(started.session.ephemeralPublicKey),
      base64Encode(started.salt),
    );
    expect(reveal, PairRevealOutcome.rejected);
  });

  test('confirmForAlreadyPairedDeviceIdIsRejected', () async {
    final h = await _Harness.create();
    final existingKey = List<int>.generate(32, (i) => i);
    await h.pairedStore.addDevice(
      PairedDevice(id: _initiatorA, name: 'Existing'),
      SecretKey(existingKey),
    );

    final code = h.coordinator.startHosting();
    final initiation = await h.start(_initiatorA, code);
    h.coordinator.confirmHostedPairing();
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );

    expect(outcome, PairConfirmOutcome.alreadyPaired);
    expect(await h.storedKey(_initiatorA), existingKey);
    expect(h.pairedStore.devices.map((d) => d.name), ['Existing']);
  });

  test('startHostingClearsPreviousPendingState', () async {
    final h = await _Harness.create();
    final oldCode = h.coordinator.startHosting();
    final stale = await h.start(_initiatorA, oldCode);

    final newCode = h.coordinator.startHosting();
    expect(h.coordinator.hostComparison, isNull);

    // The stale initiator no longer occupies the new code...
    await h.start(_initiatorB, newCode);

    // ...and its old proof cannot complete pairing.
    h.coordinator.confirmHostedPairing();
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      stale.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('revealWithWrongKeyInvalidatesCode', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    final started = await h.startWithoutReveal(_initiatorA);
    final other = PairingSession();
    await other.init();

    final outcome = await h.coordinator.handlePairReveal(
      _initiatorA,
      base64Encode(other.ephemeralPublicKey),
      base64Encode(started.salt),
    );
    expect(outcome, PairRevealOutcome.invalid);
    expect(h.coordinator.hostCode, isNull);
    expect(h.coordinator.hostComparison, isNull);

    // The honest reveal is now refused too, and so is a fresh start on the same code.
    final honest = await h.coordinator.handlePairReveal(
      _initiatorA,
      base64Encode(started.session.ephemeralPublicKey),
      base64Encode(started.salt),
    );
    expect(honest, PairRevealOutcome.rejected);
    await expectLater(
      h.start(_initiatorA, code),
      throwsA(isA<PairingRejectedException>()),
    );
  });

  test('keysAreNotStoredUntilBothConfirm', () async {
    final (target, initiator, _) = await _pair();
    final code = target.coordinator.startHosting();

    final comparison = await initiator.coordinator.startPairing(
      _targetPeer,
      code,
    );
    final hosted = target.coordinator.hostComparison!;
    expect(comparison.confirmCode, hosted.confirmCode);
    expect(comparison.deviceName, 'Phone');
    expect(hosted.deviceName, 'Laptop');
    expect(initiator.coordinator.joinComparison, isNotNull);
    expect(initiator.pairedStore.devices, isEmpty);
    expect(target.pairedStore.devices, isEmpty);

    // The initiator's user confirms; the target holds the request for its own user.
    final confirming = initiator.coordinator.confirmPairing();
    await target.waitUntilConfirmIsHeld();
    expect(initiator.pairedStore.devices, isEmpty);
    expect(target.pairedStore.devices, isEmpty);

    target.coordinator.confirmHostedPairing();
    await confirming;

    final initiatorKey = await initiator.storedKey(_targetId);
    expect(initiatorKey, isNotNull);
    expect(await target.storedKey(_initiatorA), initiatorKey);
    expect(target.coordinator.hostComparison, isNull);
    expect(initiator.coordinator.joinComparison, isNull);
  });

  test('targetCancelRejectsInitiator', () async {
    final (target, initiator, _) = await _pair();
    final code = target.coordinator.startHosting();

    await initiator.coordinator.startPairing(_targetPeer, code);
    final confirming = initiator.coordinator.confirmPairing();
    await target.waitUntilConfirmIsHeld();
    target.coordinator.cancelHostedPairing();

    await expectLater(confirming, throwsA(isA<PairingNotAcceptedException>()));
    expect(initiator.pairedStore.devices, isEmpty);
    expect(target.pairedStore.devices, isEmpty);
    expect(target.coordinator.hostCode, isNull);
    expect(target.coordinator.hostComparison, isNull);
    expect(initiator.coordinator.joinComparison, isNull);
  });

  test('initiatorCancelAfterConfirmStoresNothing', () async {
    final (target, initiator, _) = await _pair();
    final code = target.coordinator.startHosting();

    await initiator.coordinator.startPairing(_targetPeer, code);
    final confirming = expectLater(
      initiator.coordinator.confirmPairing(),
      throwsA(isA<PairingCancelledException>()),
    );
    await target.waitUntilConfirmIsHeld();
    await initiator.coordinator.cancelPairing();
    target.coordinator.confirmHostedPairing();

    await confirming;
    expect(initiator.pairedStore.devices, isEmpty);
    expect(target.pairedStore.devices, isEmpty);
    expect(target.coordinator.hostCode, isNull);
    expect(target.coordinator.hostComparison, isNull);
    expect(initiator.coordinator.joinComparison, isNull);
  });

  test('targetConfirmsFirstThenInitiatorConfirms', () async {
    final (target, initiator, _) = await _pair();
    final code = target.coordinator.startHosting();

    await initiator.coordinator.startPairing(_targetPeer, code);
    target.coordinator.confirmHostedPairing();
    expect(target.coordinator.hostComparison?.localConfirmed, isTrue);
    await initiator.coordinator.confirmPairing();

    final initiatorKey = await initiator.storedKey(_targetId);
    expect(initiatorKey, isNotNull);
    expect(await target.storedKey(_initiatorA), initiatorKey);
    expect(target.coordinator.isHoldingConfirm, isFalse);
  });

  test('v1StartWithoutCommitmentGets403', () async {
    final h = await _Harness.create();
    h.coordinator.startHosting();
    final handler = ClipServer(
      identity: h.coordinator.identity,
      pairingCoordinator: h.coordinator,
      pairedStore: h.pairedStore,
      onClipReceived: (_) {},
    ).buildHandler();

    final response = await handler(
      shelf.Request(
        'POST',
        Uri.parse('http://10.0.0.2:51888/v1/pair/start'),
        body: jsonEncode({
          'deviceId': _initiatorA,
          'deviceName': 'Old phone',
          'ephemeralPublicKey': base64Encode(List<int>.filled(32, 9)),
        }),
      ),
    );
    expect(response.statusCode, 403);
  });

  test('initiatorOnlyContactsSelectedPeer', () async {
    final (target, initiator, loopback) = await _pair();
    final code = target.coordinator.startHosting();

    await initiator.coordinator.startPairing(_targetPeer, code);
    target.coordinator.confirmHostedPairing();
    await initiator.coordinator.confirmPairing();

    expect(loopback.requests.map((uri) => uri.path), [
      '/v1/pair/start',
      '/v1/pair/reveal',
      '/v1/pair/confirm',
    ]);
    expect(loopback.requests.map((uri) => uri.host).toSet(), {'10.0.0.2'});
  });

  test('confirmTimesOutAfter60s', () async {
    expect(
      PairingCoordinator.defaultConfirmHoldTimeout,
      const Duration(seconds: 60),
    );
    final h = await _Harness.create(
      confirmHoldTimeout: const Duration(milliseconds: 50),
    );
    final code = h.coordinator.startHosting();
    final initiation = await h.start(_initiatorA, code);

    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.timedOut);
    expect(h.coordinator.hostCode, isNull);
    expect(h.coordinator.hostComparison, isNull);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('hostingEndedEventFiresOnFailureAndExpiry', () async {
    final h = await _Harness.create();
    h.coordinator.startHosting();
    await h.startWithoutReveal(_initiatorA);
    final beforeFailure = h.hostingChanges;
    await h.coordinator.handlePairConfirmRequest(_initiatorA, 'AAAA');
    expect(h.coordinator.hostCode, isNull);
    expect(h.hostingChanges, greaterThan(beforeFailure));

    h.coordinator.startHosting(ttl: const Duration(milliseconds: 20));
    final beforeExpiry = h.hostingChanges;
    h.now = h.now.add(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.coordinator.hostCode, isNull);
    expect(h.hostingChanges, greaterThan(beforeExpiry));
  });

  test('initiatorSurfacesAlreadyPairedConflict', () async {
    final store = await _newStore();
    final targetSession = PairingSession();
    await targetSession.init();
    final coordinator = PairingCoordinator(
      identity: DeviceIdentity(id: _initiatorA, name: 'Phone'),
      pairedStore: store,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/v1/pair/start':
            return http.Response(
              jsonEncode({
                'deviceId': _targetId,
                'deviceName': 'Mac',
                'ephemeralPublicKey': base64Encode(
                  targetSession.ephemeralPublicKey,
                ),
              }),
              200,
            );
          case '/v1/pair/reveal':
            return http.Response(jsonEncode({'status': 'ok'}), 200);
        }
        return http.Response(jsonEncode({'status': 'alreadyPaired'}), 409);
      }),
    );

    await coordinator.startPairing(
      Peer(id: _targetId, name: 'Mac', host: '10.0.0.2', port: 51888),
      '123456',
    );
    await expectLater(
      coordinator.confirmPairing(),
      throwsA(isA<PairingAlreadyPairedException>()),
    );
    expect(store.devices, isEmpty);
    expect(coordinator.joinComparison, isNull);
  });
}
