import 'dart:typed_data';

import 'package:clipboard_companion/desktop/dib_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  Uint8List makeTestPng() {
    final image = img.Image(width: 4, height: 3);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, x * 60, y * 80, 200);
      }
    }
    return img.encodePng(image);
  }

  test('PNG -> DIB -> PNG round-trips pixel data', () {
    final png = makeTestPng();

    final dib = DibCodec.imageToDib(png);
    expect(dib, isNotNull);
    // A DIB starts with the BITMAPINFOHEADER size, not the 'BM' magic.
    expect(dib![0], isNot(0x42));

    final roundTripped = DibCodec.dibToPng(dib);
    expect(roundTripped, isNotNull);

    final original = img.decodePng(png)!;
    final restored = img.decodePng(roundTripped!)!;
    expect(restored.width, original.width);
    expect(restored.height, original.height);
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        final a = original.getPixel(x, y);
        final b = restored.getPixel(x, y);
        expect([b.r, b.g, b.b], [a.r, a.g, a.b], reason: 'pixel ($x,$y)');
      }
    }
  });

  test('imageToDib rejects undecodable bytes', () {
    expect(DibCodec.imageToDib(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('toPng re-encodes JPEG bytes as PNG and passes PNG through', () {
    final png = makeTestPng();
    expect(DibCodec.toPng(png), same(png));

    final jpg = img.encodeJpg(img.decodePng(png)!);
    final converted = DibCodec.toPng(jpg);
    expect(converted, isNotNull);
    expect(DibCodec.isPng(converted!), isTrue);
  });

  test('dibToPng rejects truncated DIBs', () {
    expect(DibCodec.dibToPng(Uint8List(10)), isNull);
  });
}
