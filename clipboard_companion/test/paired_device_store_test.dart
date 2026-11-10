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
      PairedDevice(id: '550E8400-E29B-41D4-A716-446655440000', name: 'Mac'),
      key,
    );

    final stored = await store.getKey('550e8400-e29b-41d4-a716-446655440000');
    expect(await stored?.extractBytes(), await key.extractBytes());

    await store.updateHost(
      '550e8400-e29b-41d4-a716-446655440000',
      '192.168.0.42',
    );
    expect(store.devices.single.host, '192.168.0.42');
  });

  test(
    'corrupt paired devices are quarantined and the store starts empty',
    () async {
      SharedPreferences.setMockInitialValues({'paired_devices': '{"trunc'});
      final prefs = await SharedPreferences.getInstance();

      final store = PairedDeviceStore(prefs);
      expect(store.devices, isEmpty);
      await store.quarantineIfCorrupt(
        now: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );

      const quarantinedKey = 'paired_devices.corrupt-19700101-001640';
      expect(store.devices, isEmpty);
      expect(store.quarantinedKey, quarantinedKey);
      expect(prefs.getString(quarantinedKey), '{"trunc');
      expect(prefs.getString('paired_devices'), isNull);
    },
  );

  test('healthy paired devices are not quarantined', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await PairedDeviceStore(prefs).addDevice(
      PairedDevice(id: '550e8400-e29b-41d4-a716-446655440000', name: 'Mac'),
      SecretKey(List<int>.filled(32, 7)),
    );

    final reloaded = PairedDeviceStore(prefs);
    await reloaded.quarantineIfCorrupt();

    expect(reloaded.devices.single.name, 'Mac');
    expect(reloaded.quarantinedKey, isNull);
  });
}
