import 'dart:convert';

import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/core/paired_device_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_pair_key_storage.dart';

void main() {
  test('paired key lookup is case insensitive for UUID strings', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = PairedDeviceStore(prefs, keyStorage: FakePairKeyStorage());
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

  test('keysAreWrittenToSecureStorageNotPrefs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final keyStorage = FakePairKeyStorage();
    final store = PairedDeviceStore(prefs, keyStorage: keyStorage);
    final keyBytes = List<int>.filled(32, 9);

    await store.addDevice(
      PairedDevice(id: 'ABC', name: 'Mac'),
      SecretKey(keyBytes),
    );

    expect(prefs.getKeys().where((k) => k.startsWith('pair_key_')), isEmpty);
    expect(keyStorage.values['pair_key_abc'], base64Encode(keyBytes));
    expect(await (await store.getKey('abc'))?.extractBytes(), keyBytes);

    await store.removeDevice('abc');
    expect(keyStorage.values, isEmpty);
    expect(await store.getKey('abc'), isNull);
  });

  test('existingPrefsKeysAreMigratedAndRemoved', () async {
    final legacyBytes = List<int>.filled(32, 3);
    final otherBytes = List<int>.filled(32, 4);
    SharedPreferences.setMockInitialValues({
      'paired_devices': jsonEncode([
        {'id': 'abc', 'name': 'Mac'},
        {'id': 'def', 'name': 'PC'},
      ]),
      'pair_key_abc': base64Encode(legacyBytes),
      'pair_key_def': base64Encode(otherBytes),
      'device_id': 'self',
    });
    final prefs = await SharedPreferences.getInstance();
    final keyStorage = FakePairKeyStorage();
    final store = PairedDeviceStore(prefs, keyStorage: keyStorage);

    await store.migrateLegacyKeys();

    expect(prefs.getKeys().where((k) => k.startsWith('pair_key_')), isEmpty);
    expect(prefs.getString('device_id'), 'self');
    expect(keyStorage.values, {
      'pair_key_abc': base64Encode(legacyBytes),
      'pair_key_def': base64Encode(otherBytes),
    });
    expect(await (await store.getKey('abc'))?.extractBytes(), legacyBytes);
    expect(store.devices.map((d) => d.id), ['abc', 'def']);
  });

  test(
    'getKey migrates a legacy prefs key that was not yet migrated',
    () async {
      final legacyBytes = List<int>.filled(32, 5);
      SharedPreferences.setMockInitialValues({
        'pair_key_abc': base64Encode(legacyBytes),
      });
      final prefs = await SharedPreferences.getInstance();
      final keyStorage = FakePairKeyStorage();
      final store = PairedDeviceStore(prefs, keyStorage: keyStorage);

      expect(await (await store.getKey('ABC'))?.extractBytes(), legacyBytes);
      expect(prefs.getString('pair_key_abc'), isNull);
      expect(keyStorage.values['pair_key_abc'], base64Encode(legacyBytes));
    },
  );

  test(
    'failed secure write keeps the prefs key and a later getKey retries',
    () async {
      final legacyBytes = List<int>.filled(32, 6);
      SharedPreferences.setMockInitialValues({
        'pair_key_abc': base64Encode(legacyBytes),
      });
      final prefs = await SharedPreferences.getInstance();
      final keyStorage = FakePairKeyStorage()..throwOnWrite = true;
      final store = PairedDeviceStore(prefs, keyStorage: keyStorage);

      await expectLater(store.migrateLegacyKeys(), throwsStateError);
      expect(prefs.getString('pair_key_abc'), base64Encode(legacyBytes));

      // Sync keeps working from the prefs copy while the keystore is down.
      expect(await (await store.getKey('abc'))?.extractBytes(), legacyBytes);
      expect(prefs.getString('pair_key_abc'), base64Encode(legacyBytes));
      expect(keyStorage.values, isEmpty);

      keyStorage.throwOnWrite = false;
      expect(await (await store.getKey('abc'))?.extractBytes(), legacyBytes);
      expect(prefs.getString('pair_key_abc'), isNull);
      expect(keyStorage.values['pair_key_abc'], base64Encode(legacyBytes));
    },
  );

  test('migration never overwrites a newer secure key', () async {
    final staleBytes = List<int>.filled(32, 1);
    final newerBytes = List<int>.filled(32, 2);
    SharedPreferences.setMockInitialValues({
      'pair_key_abc': base64Encode(staleBytes),
    });
    final prefs = await SharedPreferences.getInstance();
    final keyStorage = FakePairKeyStorage()
      ..values['pair_key_abc'] = base64Encode(newerBytes);
    final store = PairedDeviceStore(prefs, keyStorage: keyStorage);

    await store.migrateLegacyKeys();

    expect(prefs.getString('pair_key_abc'), isNull);
    expect(keyStorage.values['pair_key_abc'], base64Encode(newerBytes));
    expect(await (await store.getKey('abc'))?.extractBytes(), newerBytes);
  });
}
