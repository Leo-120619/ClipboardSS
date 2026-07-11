import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'models.dart';

class PairedDeviceStore {
  final SharedPreferences _prefs;

  PairedDeviceStore(this._prefs);

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
    await _prefs.setString('$_keysPrefix$canonicalId', base64Encode(keyBytes));

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
    await _prefs.remove('$_keysPrefix$canonicalId');
    final list = devices;
    list.removeWhere((e) => e.id == canonicalId);
    await _prefs.setString(
      _devicesKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<SecretKey?> getKey(String deviceId) async {
    final str = _prefs.getString('$_keysPrefix${canonicalDeviceId(deviceId)}');
    if (str == null) return null;
    return SecretKey(base64Decode(str));
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

  bool isConnected(String id) =>
      devices
          .where((device) => device.id == canonicalDeviceId(id))
          .firstOrNull
          ?.connected ??
      false;
}
