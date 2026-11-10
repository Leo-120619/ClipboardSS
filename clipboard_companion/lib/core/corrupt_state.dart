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
/// earlier copy. The preferences cache updates synchronously; persistence completes in
/// the background.
String quarantineCorruptPref(
  SharedPreferences prefs,
  String key,
  DateTime now,
) {
  final value = prefs.getString(key);
  final baseKey = '$key.corrupt-${corruptStateTimestamp(now)}';
  var destination = baseKey;
  for (var suffix = 2; prefs.containsKey(destination); suffix++) {
    destination = '$baseKey-$suffix';
  }
  if (value != null) prefs.setString(destination, value);
  prefs.remove(key);
  return destination;
}
