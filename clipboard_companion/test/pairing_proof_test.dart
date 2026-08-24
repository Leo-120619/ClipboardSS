import 'dart:convert';
import 'dart:async';

import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('confirmation proof uses lowercase canonical UUID strings', () async {
    final pairKey = SecretKey(List<int>.filled(32, 42));
    final proof = await PairingSession.generateConfirmationProof(
      pairKey,
      '550E8400-E29B-41D4-A716-446655440000',
      '4D967C79-47DC-4E1F-A3BD-D3160B082DA7',
    );

    final hmac = Hmac.sha256();
    final expected = await hmac.calculateMac(
      utf8.encode(
        'confirm550e8400-e29b-41d4-a716-4466554400004d967c79-47dc-4e1f-a3bd-d3160b082da7',
      ),
      secretKey: pairKey,
    );

    expect(proof, expected.bytes);
  });

  test('pairing bounds stalled HTTP requests', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final coordinator = PairingCoordinator(
      identity: DeviceIdentity(
        id: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
        name: 'Phone',
      ),
      pairedStore: PairedDeviceStore(prefs),
      client: MockClient((request) => Completer<http.Response>().future),
      requestTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      coordinator.startPairing(
        Peer(
          id: '550e8400-e29b-41d4-a716-446655440000',
          name: 'Mac',
          host: '10.0.0.2',
          port: 51888,
        ),
        '123456',
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
