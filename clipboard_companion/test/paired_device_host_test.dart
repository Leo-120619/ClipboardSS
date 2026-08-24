import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('PairedDevice host round-trips and legacy JSON decodes to null', () {
    final legacy = PairedDevice.fromJson({'id': 'ABC', 'name': 'Old'});
    expect(legacy.host, isNull);

    final device = PairedDevice(id: 'abc', name: 'Mac', host: '192.168.0.4');
    final back = PairedDevice.fromJson(device.toJson());
    expect(back.id, 'abc');
    expect(back.host, '192.168.0.4');
  });

  test('store canonicalization preserves host', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = PairedDeviceStore(prefs);

    await store.addDevice(
      PairedDevice(
        id: 'ABC',
        name: 'Mac',
        host: '192.168.0.4',
      ),
      SecretKey(List<int>.filled(32, 7)),
    );

    expect(store.devices.single.id, 'abc');
    expect(store.devices.single.host, '192.168.0.4');
  });
}
