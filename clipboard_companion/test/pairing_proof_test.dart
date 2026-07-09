import 'dart:convert';

import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

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
      utf8.encode('confirm550e8400-e29b-41d4-a716-4466554400004d967c79-47dc-4e1f-a3bd-d3160b082da7'),
      secretKey: pairKey,
    );

    expect(proof, expected.bytes);
  });
}
