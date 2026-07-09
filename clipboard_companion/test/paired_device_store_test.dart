import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('paired key lookup is case insensitive for UUID strings', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = PairedDeviceStore(prefs);
    final key = SecretKey(List<int>.filled(32, 7));

    await store.addDevice(
      PairedDevice(
        id: '550E8400-E29B-41D4-A716-446655440000',
        name: 'Mac',
      ),
      key,
    );

    final stored = await store.getKey('550e8400-e29b-41d4-a716-446655440000');
    expect(await stored?.extractBytes(), await key.extractBytes());
  });
}
