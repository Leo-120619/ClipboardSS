import 'package:clipboard_companion/core/paired_device_store.dart';

/// In-memory [PairKeyStorage] so tests never touch the platform keystore.
class FakePairKeyStorage implements PairKeyStorage {
  final Map<String, String> values = {};

  /// When true, [write] throws, simulating an unavailable keystore.
  bool throwOnWrite = false;

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async {
    if (throwOnWrite) throw StateError('keystore unavailable');
    values[name] = value;
  }

  @override
  Future<void> delete(String name) async => values.remove(name);
}
