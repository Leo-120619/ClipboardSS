import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

abstract final class ContentHasher {
  static String textHash(String text) => _hash(utf8.encode(text), 'text');

  static String imageHash(List<int> bytes) => _hash(bytes, 'image');

  static String _hash(List<int> bytes, String namespace) {
    final namespaced = BytesBuilder(copy: false)
      ..add(utf8.encode(namespace))
      ..addByte(0)
      ..add(bytes);
    return sha256.convert(namespaced.takeBytes()).toString();
  }
}
