import 'dart:convert';
import 'dart:math';

import 'package:clipboard_companion/core/clip_server.dart';
import 'package:clipboard_companion/core/crypto_utils.dart';
import 'package:clipboard_companion/core/image_validation.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/pairing_coordinator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'file_transfer_test_support.dart';

final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('sanitizedImageExtension', () {
    const cases = {
      'png': 'png',
      'JPG': 'jpg',
      '': 'png',
      'x/../../evil.cmd': 'png',
      'a.b': 'png',
      'toolongext': 'png',
    };
    cases.forEach((input, expected) {
      test('"$input" -> "$expected"', () {
        expect(sanitizedImageExtension(input), expected);
      });
    });
  });

  group('isRecognizedImage', () {
    test('accepts known signatures', () {
      expect(isRecognizedImage(_onePixelPng), isTrue);
      expect(isRecognizedImage([0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
      expect(isRecognizedImage(ascii.encode('GIF89a\x01\x00')), isTrue);
      expect(isRecognizedImage([0x42, 0x4D, 0, 0]), isTrue);
      expect(isRecognizedImage([0x49, 0x49, 0x2A, 0x00]), isTrue);
      expect(isRecognizedImage([0x4D, 0x4D, 0x00, 0x2A]), isTrue);
      expect(
        isRecognizedImage(ascii.encode('RIFF\x00\x00\x00\x00WEBP')),
        isTrue,
      );
    });

    test('rejects unknown or truncated data', () {
      expect(isRecognizedImage(const []), isFalse);
      expect(isRecognizedImage([0x89, 0x50, 0x4E, 0x47]), isFalse);
      expect(
        isRecognizedImage(ascii.encode('RIFF\x00\x00\x00\x00WAVE')),
        isFalse,
      );
      expect(isRecognizedImage([0x4D, 0x5A, 0x90, 0x00]), isFalse);
    });
  });

  group('ClipServer /v1/clip image validation', () {
    const peerId = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
    final key = SecretKey(List<int>.filled(32, 5));

    Future<(Handler, List<ClipPayload>)> makeHandler() async {
      final store = await makePairedStore(peerId, key);
      final identity = DeviceIdentity(
        id: 'cccccccc-0000-0000-0000-000000000000',
        name: 'Companion',
      );
      final received = <ClipPayload>[];
      final server = ClipServer(
        identity: identity,
        pairingCoordinator: PairingCoordinator(
          identity: identity,
          pairedStore: store,
        ),
        pairedStore: store,
        onClipReceived: received.add,
      );
      return (server.buildHandler(), received);
    }

    Future<Response> postImage(
      Handler handler,
      List<int> bytes,
      String extension,
    ) async {
      final payload = ClipPayload(
        id: 'a1b2c3d4-0000-0000-0000-000000000001',
        type: ClipType.image,
        createdAt: DateTime.utc(2026, 11, 10),
        imageBase64: base64Encode(bytes),
        imageExtension: extension,
        previewText: 'Image',
        contentHash: 'ignored',
        sourceDeviceName: 'Peer',
      );
      final envelope = await CryptoEnvelopeUtils.seal(payload, peerId, key);
      return handler(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/clip'),
          body: jsonEncode(envelope.toJson()),
        ),
      );
    }

    test('undecodable image is rejected and not stored', () async {
      final (handler, received) = await makeHandler();
      final random = Random(20261110);
      final bytes = [
        0x89,
        0x50,
        0x4E,
        0x47,
        for (var i = 0; i < 32; i++) random.nextInt(256),
      ];

      final response = await postImage(handler, bytes, 'png');

      expect(response.statusCode, 400);
      expect(received, isEmpty);
    });

    test('valid image is delivered with a sanitized extension', () async {
      final (handler, received) = await makeHandler();

      final response = await postImage(
        handler,
        _onePixelPng,
        'x/../../evil.cmd',
      );

      expect(response.statusCode, 200);
      expect(received.single.imageExtension, 'png');
      expect(base64Decode(received.single.imageBase64!), _onePixelPng);
    });
  });
}
