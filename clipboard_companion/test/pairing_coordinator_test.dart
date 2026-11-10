import 'dart:convert';

import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _targetId = '4d967c79-47dc-4e1f-a3bd-d3160b082da7';
const _initiatorA = '550e8400-e29b-41d4-a716-446655440000';
const _initiatorB = '6fa459ea-ee8a-3ca4-894e-db77e160355e';

class _Initiation {
  final List<int> pairKey;
  final String proofBase64;
  _Initiation(this.pairKey, this.proofBase64);
}

class _Harness {
  final PairedDeviceStore pairedStore;
  final PairingCoordinator coordinator;
  DateTime now = DateTime.utc(2027, 1, 15, 12);

  _Harness._(this.pairedStore, this.coordinator);

  static Future<_Harness> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = PairedDeviceStore(await SharedPreferences.getInstance());
    late _Harness harness;
    final coordinator = PairingCoordinator(
      identity: DeviceIdentity(id: _targetId, name: 'Phone'),
      pairedStore: store,
      clock: () => harness.now,
    );
    harness = _Harness._(store, coordinator);
    return harness;
  }

  /// Plays the initiator side of `/v1/pair/start` and derives the proof it would send to `/v1/pair/confirm`.
  Future<_Initiation> start(String initiatorId, String code) async {
    final session = PairingSession();
    await session.init();
    final targetPublicKey = await coordinator.handlePairStart(
      initiatorId,
      'Initiator',
      base64Encode(session.ephemeralPublicKey),
      '10.0.0.9',
    );
    final result = await session.completePairing(
      remotePublicKeyBytes: base64Decode(targetPublicKey),
      initiatorId: initiatorId,
      targetId: _targetId,
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
}

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
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      initiation.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('secondInitiatorWhilePendingIsRejected', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    final first = await h.start(_initiatorA, code);

    await expectLater(
      h.start(_initiatorB, code),
      throwsA(isA<PairingRejectedException>()),
    );

    // The refused start did not displace the pending initiator.
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      first.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.paired);
    expect(await h.storedKey(_initiatorA), first.pairKey);
  });

  test('secondStartFromSameInitiatorReplacesPending', () async {
    final h = await _Harness.create();
    final code = h.coordinator.startHosting();
    await h.start(_initiatorA, code);
    final second = await h.start(_initiatorA, code);

    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      second.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.paired);
    expect(await h.storedKey(_initiatorA), second.pairKey);
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

    // The stale initiator no longer occupies the new code...
    await h.start(_initiatorB, newCode);

    // ...and its old proof cannot complete pairing.
    final outcome = await h.coordinator.handlePairConfirmRequest(
      _initiatorA,
      stale.proofBase64,
    );
    expect(outcome, PairConfirmOutcome.rejected);
    expect(await h.storedKey(_initiatorA), isNull);
  });

  test('initiatorSurfacesAlreadyPairedConflict', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PairedDeviceStore(await SharedPreferences.getInstance());
    final targetSession = PairingSession();
    await targetSession.init();
    final coordinator = PairingCoordinator(
      identity: DeviceIdentity(id: _initiatorA, name: 'Phone'),
      pairedStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/v1/pair/start') {
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
        }
        return http.Response(jsonEncode({'status': 'alreadyPaired'}), 409);
      }),
    );

    await expectLater(
      coordinator.startPairing(
        Peer(id: _targetId, name: 'Mac', host: '10.0.0.2', port: 51888),
        '123456',
      ),
      throwsA(isA<PairingAlreadyPairedException>()),
    );
    expect(store.devices, isEmpty);
  });
}
