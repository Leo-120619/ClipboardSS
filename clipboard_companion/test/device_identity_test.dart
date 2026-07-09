import 'package:clipboard_companion/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalDeviceId lowercases UUID strings', () {
    expect(
      canonicalDeviceId('550E8400-E29B-41D4-A716-446655440000'),
      '550e8400-e29b-41d4-a716-446655440000',
    );
  });

  test('Peer stores canonical lowercase IDs', () {
    final peer = Peer(
      id: '550E8400-E29B-41D4-A716-446655440000',
      name: 'Mac',
      host: 'mac.local',
      port: 1234,
    );

    expect(peer.id, '550e8400-e29b-41d4-a716-446655440000');
  });
}
