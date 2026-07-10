import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract final class ContentHasher {
  static String textHash(String text) => _hash(utf8.encode(text), 'text');

  static String imageHash(List<int> bytes) => _hash(bytes, 'image');

  /// In-memory file hash, `SHA256("file" + 0x00 + bytes)`.
  static String fileHash(List<int> bytes) => _hash(bytes, 'file');

  /// Streaming file hash — reads the file incrementally so it never loads the whole
  /// file into memory. Produces the same value as [fileHash] over the file's bytes.
  static Future<String> fileHashOfFile(File file) async {
    Digest? digest;
    final sink = ChunkedConversionSink<Digest>.withCallback((chunks) => digest = chunks.single);
    final input = sha256.startChunkedConversion(sink);
    input.add(utf8.encode('file'));
    input.add(const [0]);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digest!.toString();
  }

  static String _hash(List<int> bytes, String namespace) {
    final namespaced = BytesBuilder(copy: false)
      ..add(utf8.encode(namespace))
      ..addByte(0)
      ..add(bytes);
    return sha256.convert(namespaced.takeBytes()).toString();
  }
}
