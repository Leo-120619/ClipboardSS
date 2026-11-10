import 'package:shared_preferences/shared_preferences.dart';

/// UTC `yyyyMMdd-HHmmss`, the quarantine suffix format shared with the Mac and Windows apps.
String corruptStateTimestamp(DateTime now) {
  final utc = now.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
      '-${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
}

/// Moves an unreadable stored value to `<key>.corrupt-<timestamp>` so the app can start
/// with empty state instead of failing, and returns the new key. Never overwrites an
/// earlier copy, and removes the original only after the copy was stored.
Future<String> quarantineCorruptPref(
  SharedPreferences prefs,
  String key,
  DateTime now,
) async {
  final value = prefs.getString(key);
  final baseKey = '$key.corrupt-${corruptStateTimestamp(now)}';
  var destination = baseKey;
  for (var suffix = 2; prefs.containsKey(destination); suffix++) {
    destination = '$baseKey-$suffix';
  }
  if (value != null && !await prefs.setString(destination, value)) {
    throw StateError('Could not keep a copy of the unreadable "$key" value.');
  }
  await prefs.remove(key);
  return destination;
}
