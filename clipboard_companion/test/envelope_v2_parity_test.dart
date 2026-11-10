import 'dart:convert';

import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Pinned vector — must match docs/wire-protocol.md byte-for-byte.
  final pairKey = SecretKey(List<int>.generate(32, (i) => i));
  const source = '11111111-1111-1111-1111-111111111111';
  const recipient = '22222222-2222-2222-2222-222222222222';
  final pinnedNonce = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
  final pinnedPlaintext = utf8.encode('{"a":1}');
  const pinnedCiphertextHex = '127e1dfb0b3bc54f07dfeda46cd545278be6adeef430c1';

  Future<ClipEnvelope> sealSample(EnvelopePurpose purpose) =>
      CryptoEnvelopeUtils.sealJson(
        {'a': 1},
        purpose: purpose,
        sourceDeviceId: source,
        recipientDeviceId: recipient,
        pairKey: pairKey,
      );

  test(
    'associated data is ClipboardSS/2|purpose|source|recipient in lowercase',
    () {
      final aad = CryptoEnvelopeUtils.associatedData(
        EnvelopePurpose.fileOffer,
        source.toUpperCase(),
        recipient.toUpperCase(),
      );
      expect(utf8.decode(aad), 'ClipboardSS/2|file-offer|$source|$recipient');
    },
  );

  test('envelopeV2MatchesPinnedVector', () async {
    final envelope = await CryptoEnvelopeUtils.sealBytes(
      pinnedPlaintext,
      purpose: EnvelopePurpose.clip,
      sourceDeviceId: source,
      recipientDeviceId: recipient,
      pairKey: pairKey,
      nonce: pinnedNonce,
    );
    expect(envelope.v, 2);
    expect(envelope.nonce, base64Encode(pinnedNonce));
    expect(_hex(base64Decode(envelope.ciphertext)), pinnedCiphertextHex);

    final opened = await CryptoEnvelopeUtils.openBytes(
      envelope,
      purpose: EnvelopePurpose.clip,
      recipientDeviceId: recipient,
      pairKey: pairKey,
    );
    expect(opened, pinnedPlaintext);
  });

  test('round-trips a JSON payload', () async {
    final envelope = await sealSample(EnvelopePurpose.clip);
    expect(envelope.toJson()['v'], 2);
    final opened = await CryptoEnvelopeUtils.openJson(
      envelope,
      purpose: EnvelopePurpose.clip,
      recipientDeviceId: recipient,
      pairKey: pairKey,
    );
    expect(opened, {'a': 1});
  });

  test('openFailsWithWrongPurpose', () async {
    final envelope = await sealSample(EnvelopePurpose.fileOffer);
    for (final purpose in [
      EnvelopePurpose.clip,
      EnvelopePurpose.fileFinish,
      EnvelopePurpose.fileCancel,
    ]) {
      await expectLater(
        CryptoEnvelopeUtils.openJson(
          envelope,
          purpose: purpose,
          recipientDeviceId: recipient,
          pairKey: pairKey,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    }
  });

  test('openFailsWhenReflectedToSender', () async {
    final envelope = await sealSample(EnvelopePurpose.clip);
    final reflected = ClipEnvelope(
      v: 2,
      sourceDeviceId: recipient,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext,
    );
    await expectLater(
      CryptoEnvelopeUtils.openJson(
        reflected,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: source,
        pairKey: pairKey,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(
      CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: source,
        pairKey: pairKey,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('openFailsWithWrongRecipient', () async {
    final envelope = await sealSample(EnvelopePurpose.clip);
    await expectLater(
      CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: '33333333-3333-3333-3333-333333333333',
        pairKey: pairKey,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('open rejects a v1 envelope as unsupported', () async {
    final envelope = await sealSample(EnvelopePurpose.clip);
    final v1 = ClipEnvelope(
      v: 1,
      sourceDeviceId: source,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext,
    );
    await expectLater(
      CryptoEnvelopeUtils.openJson(
        v1,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: recipient,
        pairKey: pairKey,
      ),
      throwsA(isA<UnsupportedEnvelopeVersionException>()),
    );
  });
}
