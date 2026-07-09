import 'dart:convert';

import 'package:clipboard_companion/core/clip_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('identity body has id, name, v', () {
    final body = jsonDecode(
      ClipServer.identityBody(
        '367c33ad-64ef-48ac-9c7f-f08f55b7d780',
        'Android Device',
      ),
    ) as Map<String, dynamic>;

    expect(body['deviceId'], '367c33ad-64ef-48ac-9c7f-f08f55b7d780');
    expect(body['deviceName'], 'Android Device');
    expect(body['v'], 1);
  });
}
