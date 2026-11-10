import 'dart:convert';

import 'models.dart';

final _safeExtension = RegExp(r'^[A-Za-z0-9]{1,5}$');

/// Returns the lowercased extension when it is 1-5 ASCII letters or digits,
/// otherwise `"png"`. The extension is peer-supplied, so anything else
/// (separators, dots, `..`) is discarded.
String sanitizedImageExtension(String fileExtension) =>
    _safeExtension.hasMatch(fileExtension)
    ? fileExtension.toLowerCase()
    : 'png';

const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _pngHeaderChunk = [0x49, 0x48, 0x44, 0x52]; // "IHDR"
const _jpeg = [0xFF, 0xD8, 0xFF];
const _gif87 = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61];
const _gif89 = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
const _bmp = [0x42, 0x4D];
const _tiffLittleEndian = [0x49, 0x49, 0x2A, 0x00];
const _tiffBigEndian = [0x4D, 0x4D, 0x00, 0x2A];
const _riff = [0x52, 0x49, 0x46, 0x46];
const _webp = [0x57, 0x45, 0x42, 0x50];

bool _matchesAt(List<int> data, int offset, List<int> signature) {
  if (data.length < offset + signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (data[offset + i] != signature[i]) return false;
  }
  return true;
}

/// Magic-number check (PNG, JPEG, GIF, BMP, TIFF, WebP), matching the
/// Windows Core default validator.
bool isRecognizedImage(List<int> data) {
  if (_matchesAt(data, 0, _png)) {
    // The first chunk of every PNG is IHDR (type at bytes 12..15).
    return _matchesAt(data, 12, _pngHeaderChunk);
  }
  return _matchesAt(data, 0, _jpeg) ||
      _matchesAt(data, 0, _gif87) ||
      _matchesAt(data, 0, _gif89) ||
      _matchesAt(data, 0, _bmp) ||
      _matchesAt(data, 0, _tiffLittleEndian) ||
      _matchesAt(data, 0, _tiffBigEndian) ||
      (_matchesAt(data, 0, _riff) && _matchesAt(data, 8, _webp));
}

/// Validates a clip received from a peer before it is stored. Text clips pass
/// through unchanged; image clips must carry recognizable image bytes and get
/// a sanitized extension. Returns `null` when the clip must be rejected.
ClipPayload? acceptReceivedClip(ClipPayload payload) {
  if (payload.type != ClipType.image) return payload;
  final base64 = payload.imageBase64;
  if (base64 == null || base64.isEmpty) return null;
  final List<int> bytes;
  try {
    bytes = base64Decode(base64);
  } on FormatException {
    return null;
  }
  if (!isRecognizedImage(bytes)) return null;
  return ClipPayload(
    id: payload.id,
    type: payload.type,
    createdAt: payload.createdAt,
    text: payload.text,
    imageBase64: payload.imageBase64,
    imageExtension: sanitizedImageExtension(payload.imageExtension ?? 'png'),
    previewText: payload.previewText,
    contentHash: payload.contentHash,
    sourceDeviceName: payload.sourceDeviceName,
  );
}
