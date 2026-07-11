import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

abstract class ReceivedFileNotifications {
  Future<void> initialize();
  Future<void> showReceivedFile({
    required String transferId,
    required String fileName,
    String? savedPath,
  });
}

class LocalReceivedFileNotifications implements ReceivedFileNotifications {
  LocalReceivedFileNotifications({this.openMobileDownloads});

  final Future<bool> Function()? openMobileDownloads;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedTransfers = <String>{};
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        windows: WindowsInitializationSettings(
          appName: 'Clipboard Companion',
          appUserModelId: 'ClipboardSS.ClipboardCompanion',
          guid: '4d1f882e-254f-4fa7-b793-9f26ad623a83',
        ),
      );
      _initialized =
          await _plugin.initialize(
            settings: settings,
            onDidReceiveNotificationResponse: _onNotificationResponse,
          ) ??
          false;

      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true, badge: false);
      }
    } catch (_) {
      _initialized = false;
    }
  }

  @override
  Future<void> showReceivedFile({
    required String transferId,
    required String fileName,
    String? savedPath,
  }) async {
    if (!_initialized || !_notifiedTransfers.add(transferId)) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'received_files',
          'Received files',
          channelDescription:
              'Notifications for files received from paired devices',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        windows: WindowsNotificationDetails(),
      );
      await _plugin.show(
        id: transferId.hashCode & 0x7fffffff,
        title: 'File received',
        body: fileName,
        notificationDetails: details,
        payload: jsonEncode(<String, String?>{
          'fileName': fileName,
          'savedPath': savedPath,
        }),
      );
    } catch (_) {
      // Notification delivery must never affect a completed transfer.
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    try {
      final value = jsonDecode(payload) as Map<String, dynamic>;
      final path = value['savedPath'] as String?;
      if (Platform.isWindows && path != null && File(path).existsSync()) {
        Process.start('explorer.exe', <String>['/select,', path]);
      } else if ((Platform.isAndroid || Platform.isIOS) &&
          openMobileDownloads != null) {
        openMobileDownloads!();
      }
    } catch (_) {
      // A stale or malformed notification payload is safe to ignore.
    }
  }
}
