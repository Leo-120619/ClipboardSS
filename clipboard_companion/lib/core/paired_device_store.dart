import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'corrupt_state.dart';
import 'models.dart';

/// Where pair keys live. Kept separate from [SharedPreferences], which is a
/// plaintext file that backups and other tooling can read.
abstract class PairKeyStorage {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

/// Platform secure storage via flutter_secure_storage: Android Keystore, iOS
/// Keychain, and on Windows AES-GCM files whose key is in Credential Manager.
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

  /// Where an unreadable device list was moved at startup, so the UI can tell the user once.
  String? get quarantinedKey => _quarantinedKey;
  String? _quarantinedKey;

  /// Call once at startup: moves an undecodable device list aside (an unreadable list
  /// already reads as empty) and records where it went.
  Future<void> quarantineIfCorrupt({
    DateTime Function() now = DateTime.now,
  }) async {
    if (_decodeDevices() != null) return;
    _quarantinedKey = await quarantineCorruptPref(_prefs, _devicesKey, now());
  }

  static const String _devicesKey = 'paired_devices';
  static const String _keysPrefix = 'pair_key_';

  List<PairedDevice> get devices => _decodeDevices() ?? [];

  /// Returns null when the stored list exists but cannot be decoded.
  List<PairedDevice>? _decodeDevices() {
    final str = _prefs.getString(_devicesKey);
    if (str == null) return [];
    try {
      final list = jsonDecode(str) as List;
      return list
          .map((e) => PairedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
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
    final secure = await _keys.read(name);
    if (secure != null) return SecretKey(base64Decode(secure));
    final legacy = _prefs.getString(name);
    if (legacy == null) return null;
    try {
      await _migrateLegacyKey(name);
    } catch (_) {
      // Keystore unavailable: keep syncing from the prefs copy, retry next time.
    }
    return SecretKey(base64Decode(legacy));
  }

  /// One-time move of pre-secure-storage `pair_key_<id>` prefs entries into
  /// [PairKeyStorage]. Each prefs entry is removed only after its write
  /// succeeds; a write failure is rethrown and leaves the entry in place.
  Future<void> migrateLegacyKeys() async {
    final legacy = _prefs.getKeys().where((k) => k.startsWith(_keysPrefix));
    for (final name in legacy.toList()) {
      await _migrateLegacyKey(name);
    }
  }

  /// Moves one prefs key into secure storage. A key already in secure storage
  /// is newer (written by [addDevice]) and wins; the prefs copy is dropped.
  Future<void> _migrateLegacyKey(String name) async {
    final value = _prefs.getString(name);
    if (value == null) return;
    if (await _keys.read(name) == null) await _keys.write(name, value);
    await _prefs.remove(name);
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
