import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'models.dart';

/// Where pair keys live. Kept separate from [SharedPreferences], which is a
/// plaintext file that backups and other tooling can read.
abstract class PairKeyStorage {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

/// Platform keystore (Android Keystore, iOS Keychain, Windows DPAPI).
class SecurePairKeyStorage implements PairKeyStorage {
  final FlutterSecureStorage _storage;

  SecurePairKeyStorage([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  @override
  Future<String?> read(String name) => _storage.read(key: name);

  @override
  Future<void> write(String name, String value) =>
      _storage.write(key: name, value: value);

  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}

class PairedDeviceStore {
  final SharedPreferences _prefs;
  final PairKeyStorage _keys;

  PairedDeviceStore(this._prefs, {PairKeyStorage? keyStorage})
    : _keys = keyStorage ?? SecurePairKeyStorage();

  static const String _devicesKey = 'paired_devices';
  static const String _keysPrefix = 'pair_key_';

  List<PairedDevice> get devices {
    final str = _prefs.getString(_devicesKey);
    if (str == null) return [];
    final list = jsonDecode(str) as List;
    return list.map((e) => PairedDevice.fromJson(e)).toList();
  }

  Future<void> addDevice(PairedDevice device, SecretKey key) async {
    final canonicalId = canonicalDeviceId(device.id);
    // store key
    final keyBytes = await key.extractBytes();
    await _keys.write('$_keysPrefix$canonicalId', base64Encode(keyBytes));
    await _prefs.remove('$_keysPrefix$canonicalId');

    // store device
    final list = devices;
    final index = list.indexWhere((e) => e.id == canonicalId);
    final previous = index == -1 ? null : list[index];
    // Re-pairing refreshes discovery data but does not resume a locally paused device.
    final canonicalDevice = PairedDevice(
      id: canonicalId,
      name: device.name,
      host: device.host,
      connected: previous?.connected ?? device.connected,
    );
    if (index != -1) {
      list[index] = canonicalDevice;
    } else {
      list.add(canonicalDevice);
    }
    await _prefs.setString(
      _devicesKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeDevice(String id) async {
    final canonicalId = canonicalDeviceId(id);
    await _keys.delete('$_keysPrefix$canonicalId');
    await _prefs.remove('$_keysPrefix$canonicalId');
    final list = devices;
    list.removeWhere((e) => e.id == canonicalId);
    await _prefs.setString(
      _devicesKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<SecretKey?> getKey(String deviceId) async {
    final name = '$_keysPrefix${canonicalDeviceId(deviceId)}';
    final str = await _keys.read(name) ?? await _migrateLegacyKey(name);
    if (str == null) return null;
    return SecretKey(base64Decode(str));
  }

  /// One-time move of pre-secure-storage `pair_key_<id>` prefs entries into
  /// [PairKeyStorage]. Each prefs entry is removed only after its write succeeds.
  Future<void> migrateLegacyKeys() async {
    final legacy = _prefs.getKeys().where((k) => k.startsWith(_keysPrefix));
    for (final name in legacy.toList()) {
      await _migrateLegacyKey(name);
    }
  }

  Future<String?> _migrateLegacyKey(String name) async {
    final value = _prefs.getString(name);
    if (value == null) return null;
    await _keys.write(name, value);
    await _prefs.remove(name);
    return value;
  }

  Future<void> setConnected(String id, bool connected) async {
    final canonicalId = canonicalDeviceId(id);
    final list = devices;
    final index = list.indexWhere((e) => e.id == canonicalId);
    if (index == -1) return;
    final device = list[index];
    list[index] = PairedDevice(
      id: device.id,
      name: device.name,
      host: device.host,
      connected: connected,
    );
    await _prefs.setString(
      _devicesKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> updateHost(String id, String host) async {
    final canonicalId = canonicalDeviceId(id);
    final list = devices;
    final index = list.indexWhere((device) => device.id == canonicalId);
    if (index == -1) return;
    final device = list[index];
    list[index] = PairedDevice(
      id: device.id,
      name: device.name,
      host: host,
      connected: device.connected,
    );
    await _prefs.setString(
      _devicesKey,
      jsonEncode(list.map((device) => device.toJson()).toList()),
    );
  }

  bool isConnected(String id) =>
      devices
          .where((device) => device.id == canonicalDeviceId(id))
          .firstOrNull
          ?.connected ??
      false;
}
