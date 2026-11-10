import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test(
    'pairing derivation is symmetric and bound to the 6-digit code',
    () async {
      final initiator = PairingSession();
      final target = PairingSession();
      await initiator.init();
      await target.init();

      final initiatorResult = await initiator.completePairing(
        remotePublicKeyBytes: target.ephemeralPublicKey,
        isInitiator: true,
        code: '123456',
      );
      final targetResult = await target.completePairing(
        remotePublicKeyBytes: initiator.ephemeralPublicKey,
        isInitiator: false,
        code: '123456',
      );
      final wrongCodeResult = await initiator.completePairing(
        remotePublicKeyBytes: target.ephemeralPublicKey,
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
    },
  );

  test('pairingV2MatchesPinnedVector', () async {
    final initiator = PairingSession();
    final target = PairingSession();
    await initiator.initFromPrivateKey(
      _hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
    );
    await target.initFromPrivateKey(
      _hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'),
    );
    final salt = List<int>.generate(16, (i) => i);
    expect(
      _toHex(initiator.ephemeralPublicKey),
      '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
    );
    expect(
      _toHex(target.ephemeralPublicKey),
      'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
    );

    final commitment = await PairingSession.commitment(
      initiator.ephemeralPublicKey,
      salt,
    );
    expect(
      _toHex(commitment),
      'c288f1b99596594082bc7d2c3684e2baef0516454e44b3cd6d7bcbd8845f4c55',
    );
    expect(
      await PairingSession.commitmentMatches(
        commitment,
        initiator.ephemeralPublicKey,
        salt,
      ),
      isTrue,
    );
    expect(
      await PairingSession.commitmentMatches(
        commitment,
        target.ephemeralPublicKey,
        salt,
      ),
      isFalse,
    );

    final initiatorResult = await initiator.completePairing(
      remotePublicKeyBytes: target.ephemeralPublicKey,
      isInitiator: true,
      code: '123456',
    );
    final targetResult = await target.completePairing(
      remotePublicKeyBytes: initiator.ephemeralPublicKey,
      isInitiator: false,
      code: '123456',
    );
    final pairKey = await initiatorResult.pairKey.extractBytes();
    expect(
      _toHex(pairKey),
      '8088860b8ecd246dbb52966bba419592f44ab2da96dec0d03725257384cdb83f',
    );
    expect(await targetResult.pairKey.extractBytes(), pairKey);
    expect(initiatorResult.confirmCode, '885454');
    expect(targetResult.confirmCode, '885454');

    final proof = await PairingSession.generateConfirmationProof(
      SecretKey(pairKey),
      '550E8400-E29B-41D4-A716-446655440000',
      '4D967C79-47DC-4E1F-A3BD-D3160B082DA7',
    );
    expect(
      _toHex(proof),
      'b4bb2c3b5b26e686aba290b1e6469b756684cb6f131b355f106905140204c23b',
    );
  });
}
