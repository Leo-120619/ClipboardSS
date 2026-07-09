import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Converts between PNG bytes and the Windows CF_DIB clipboard format.
///
/// CF_DIB is a BMP file without the 14-byte BITMAPFILEHEADER: the
/// BITMAPINFOHEADER, optional color table / bitfield masks, and pixel data.
class DibCodec {
  static const int _fileHeaderLength = 14;

  static const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47];

  static bool isPng(Uint8List bytes) {
    if (bytes.length < _pngMagic.length) return false;
    for (var i = 0; i < _pngMagic.length; i++) {
      if (bytes[i] != _pngMagic[i]) return false;
    }
    return true;
  }

  // decodeImage can throw (not just return null) on malformed input.
  static img.Image? _tryDecode(Uint8List bytes) {
    try {
      return img.decodeImage(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Re-encodes any decodable image (PNG, JPEG, ...) as PNG. Returns the
  /// input unchanged when it is already PNG, or null when undecodable.
  static Uint8List? toPng(Uint8List imageBytes) {
    if (isPng(imageBytes)) return imageBytes;
    final decoded = _tryDecode(imageBytes);
    if (decoded == null) return null;
    return img.encodePng(decoded);
  }

  /// Encodes any decodable image as a CF_DIB payload. Returns null if the
  /// image cannot be decoded.
  static Uint8List? imageToDib(Uint8List imageBytes) {
    final decoded = _tryDecode(imageBytes);
    if (decoded == null) return null;
    final bmp = img.encodeBmp(decoded);
    return Uint8List.sublistView(bmp, _fileHeaderLength);
  }

  /// Decodes a CF_DIB payload into PNG bytes. Returns null if the DIB is
  /// malformed.
  static Uint8List? dibToPng(Uint8List dibBytes) {
    if (dibBytes.length < 40) return null;
    final data = ByteData.sublistView(dibBytes);

    final headerSize = data.getUint32(0, Endian.little);
    if (headerSize < 40 || headerSize > dibBytes.length) return null;
    final bitCount = data.getUint16(14, Endian.little);
    final compression = data.getUint32(16, Endian.little);
    var colorsUsed = data.getUint32(32, Endian.little);
    if (colorsUsed == 0 && bitCount <= 8) {
      colorsUsed = 1 << bitCount;
    }

    var pixelOffset = _fileHeaderLength + headerSize + colorsUsed * 4;
    // A 40-byte header with BI_BITFIELDS is followed by three DWORD masks.
    if (compression == 3 && headerSize == 40) {
      pixelOffset += 12;
    }

    final fileHeader = ByteData(_fileHeaderLength);
    fileHeader.setUint8(0, 0x42); // 'B'
    fileHeader.setUint8(1, 0x4D); // 'M'
    fileHeader.setUint32(2, _fileHeaderLength + dibBytes.length, Endian.little);
    fileHeader.setUint32(10, pixelOffset, Endian.little);

    final bmp = Uint8List(_fileHeaderLength + dibBytes.length);
    bmp.setRange(0, _fileHeaderLength, fileHeader.buffer.asUint8List());
    bmp.setRange(_fileHeaderLength, bmp.length, dibBytes);

    final img.Image? decoded;
    try {
      decoded = img.decodeBmp(bmp);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    return img.encodePng(decoded);
  }
}
