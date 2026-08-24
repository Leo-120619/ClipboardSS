import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing derivation is symmetric and bound to the 6-digit code', () async {
    final initiator = PairingSession();
    final target = PairingSession();
    await initiator.init();
    await target.init();

    final initiatorResult = await initiator.completePairing(
      remotePublicKeyBytes: target.ephemeralPublicKey,
      initiatorId: '550E8400-E29B-41D4-A716-446655440000',
      targetId: '4D967C79-47DC-4E1F-A3BD-D3160B082DA7',
      isInitiator: true,
      code: '123456',
    );
    final targetResult = await target.completePairing(
      remotePublicKeyBytes: initiator.ephemeralPublicKey,
      initiatorId: '550e8400-e29b-41d4-a716-446655440000',
      targetId: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
      isInitiator: false,
      code: '123456',
    );
    final wrongCodeResult = await initiator.completePairing(
      remotePublicKeyBytes: target.ephemeralPublicKey,
      initiatorId: '550e8400-e29b-41d4-a716-446655440000',
      targetId: '4d967c79-47dc-4e1f-a3bd-d3160b082da7',
      isInitiator: true,
      code: '654321',
    );

    expect(
      await initiatorResult.pairKey.extractBytes(),
      await targetResult.pairKey.extractBytes(),
    );
    expect(initiatorResult.confirmCode, targetResult.confirmCode);
    expect(initiatorResult.confirmCode, hasLength(6));
    expect(
      await wrongCodeResult.pairKey.extractBytes(),
      isNot(await initiatorResult.pairKey.extractBytes()),
    );
    expect(wrongCodeResult.confirmCode, isNot(initiatorResult.confirmCode));
  });
}
