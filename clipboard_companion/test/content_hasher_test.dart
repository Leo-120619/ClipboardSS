import 'package:clipboard_companion/core/content_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text hash matches shared SHA-256 vector', () {
    expect(
      ContentHasher.textHash('Hello, world!'),
      'f2860ecbb844a4c152aed2007055a3d41911dcb0fb7a64b996525d5b62a722e1',
    );
  });
}
