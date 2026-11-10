import 'dart:convert';

import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/replay_guard.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'file_transfer_test_support.dart';

void main() {
  const source = '11111111-1111-1111-1111-111111111111';
  const recipient = '22222222-2222-2222-2222-222222222222';
  final start = DateTime.utc(2027, 1, 15, 8);

  ReplayGuard makeGuard(MutableClock clock) => ReplayGuard(
    window: const Duration(seconds: 300),
    retention: const Duration(seconds: 600),
    now: clock.now,
  );

  group('ReplayGuard', () {
    test('freshMessageIsAccepted', () {
      final guard = makeGuard(MutableClock(start));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.ok,
      );
    });

    test('sameNonceTwiceIsReplayed', () {
      final clock = MutableClock(start);
      final guard = makeGuard(clock);
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.ok,
      );
      clock.advance(const Duration(seconds: 5));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.replayed,
      );
      // Same id in uppercase is the same sender.
      expect(
        guard.check(
          sourceDeviceId: source.toUpperCase(),
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.replayed,
      );
      // Another sender may reuse the nonce bytes under its own key.
      expect(
        guard.check(
          sourceDeviceId: recipient,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.ok,
      );
    });

    test('an alternative base64 spelling of the same nonce is replayed', () {
      final guard = makeGuard(MutableClock(start));
      final nonce = base64Encode(List<int>.filled(12, 0xfb));
      final urlSafe = nonce.replaceAll('+', '-').replaceAll('/', '_');
      expect(nonce, isNot(urlSafe));
      expect(
        guard.check(sourceDeviceId: source, nonce: nonce, sentAt: start),
        ReplayCheck.ok,
      );
      expect(
        guard.check(sourceDeviceId: source, nonce: urlSafe, sentAt: start),
        ReplayCheck.replayed,
      );
    });

    test('sentAtFourMinutesOffIsAccepted (Review Focus 1)', () {
      final guard = makeGuard(MutableClock(start));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start.subtract(const Duration(minutes: 4)),
        ),
        ReplayCheck.ok,
      );
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAC',
          sentAt: start.add(const Duration(minutes: 4)),
        ),
        ReplayCheck.ok,
      );
    });

    test('sentAtTwentyMinutesOffIsStale (Review Focus 1)', () {
      final guard = makeGuard(MutableClock(start));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start.subtract(const Duration(minutes: 20)),
        ),
        ReplayCheck.stale,
      );
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAC',
          sentAt: start.add(const Duration(minutes: 20)),
        ),
        ReplayCheck.stale,
      );
      // The window boundary is inclusive.
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAD',
          sentAt: start.subtract(const Duration(seconds: 300)),
        ),
        ReplayCheck.ok,
      );
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAE',
          sentAt: start.subtract(const Duration(seconds: 301)),
        ),
        ReplayCheck.stale,
      );
    });

    test('a stale message is not remembered', () {
      final guard = makeGuard(MutableClock(start));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start.subtract(const Duration(minutes: 20)),
        ),
        ReplayCheck.stale,
      );
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.ok,
      );
    });

    test('entriesExpireAfterRetention', () {
      final clock = MutableClock(start);
      final guard = makeGuard(clock);
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: start,
        ),
        ReplayCheck.ok,
      );
      clock.advance(const Duration(seconds: 599));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: clock.now(),
        ),
        ReplayCheck.replayed,
      );
      clock.advance(const Duration(seconds: 2));
      expect(
        guard.check(
          sourceDeviceId: source,
          nonce: 'AAAAAAAAAAAAAAAB',
          sentAt: clock.now(),
        ),
        ReplayCheck.ok,
      );
    });
  });

  group('sentAt on the wire', () {
    final pairKey = SecretKey(List<int>.generate(32, (i) => i));

    test(
      'seal stamps sentAt inside the encrypted payload in whole-second UTC',
      () async {
        final envelope = await CryptoEnvelopeUtils.sealJson(
          {'a': 1},
          purpose: EnvelopePurpose.clip,
          sourceDeviceId: source,
          recipientDeviceId: recipient,
          pairKey: pairKey,
          sentAt: DateTime.utc(2026, 11, 10, 12, 0, 0, 456),
        );
        final plaintext = await CryptoEnvelopeUtils.openBytes(
          envelope,
          purpose: EnvelopePurpose.clip,
          recipientDeviceId: recipient,
          pairKey: pairKey,
        );
        final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
        expect(json['sentAt'], '2026-11-10T12:00:00Z');
        expect(json['a'], 1);
        expect(sentAtOf(json), DateTime.utc(2026, 11, 10, 12));
      },
    );

    test('sealJson does not modify the caller map', () async {
      final json = <String, dynamic>{'a': 1};
      await CryptoEnvelopeUtils.sealJson(
        json,
        purpose: EnvelopePurpose.clip,
        sourceDeviceId: source,
        recipientDeviceId: recipient,
        pairKey: pairKey,
      );
      expect(json.containsKey('sentAt'), isFalse);
    });

    test('a payload without sentAt reads as infinitely old', () {
      expect(
        sentAtOf({'a': 1}),
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(
        sentAtOf({'sentAt': 'garbage'}),
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });
  });
}
