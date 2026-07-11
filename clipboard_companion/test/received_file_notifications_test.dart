import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/core/file_receiver.dart';
import 'package:clipboard_companion/core/received_file_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingNotifications implements ReceivedFileNotifications {
  int initializeCalls = 0;
  final List<String> transferIds = <String>[];

  @override
  Future<void> initialize() async => initializeCalls++;

  @override
  Future<void> showReceivedFile({
    required String transferId,
    required String fileName,
    String? savedPath,
  }) async {
    transferIds.add(transferId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'completed incoming transfer requests exactly one notification',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final notifications = _RecordingNotifications();
      final state = AppState(receivedFileNotifications: notifications);
      await state.init(await SharedPreferences.getInstance());

      state.handleReceiveEvent(
        FileTransferReceiveEvent(
          'started',
          'transfer-1',
          fileName: 'résumé final.pdf',
        ),
      );
      state.handleReceiveEvent(
        FileTransferReceiveEvent(
          'completed',
          'transfer-1',
          path: '/tmp/résumé final (2).pdf',
        ),
      );
      state.handleReceiveEvent(
        FileTransferReceiveEvent(
          'completed',
          'transfer-1',
          path: '/tmp/résumé final (2).pdf',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.initializeCalls, 1);
      expect(notifications.transferIds, <String>['transfer-1']);
    },
  );

  test(
    'progress, failure, cancellation, and outgoing state do not notify',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final notifications = _RecordingNotifications();
      final state = AppState(receivedFileNotifications: notifications);
      await state.init(await SharedPreferences.getInstance());

      state.handleReceiveEvent(
        FileTransferReceiveEvent('started', 'transfer-2'),
      );
      state.handleReceiveEvent(
        FileTransferReceiveEvent(
          'progress',
          'transfer-2',
          received: 1,
          total: 2,
        ),
      );
      state.handleReceiveEvent(
        FileTransferReceiveEvent('failed', 'transfer-2'),
      );
      state.handleReceiveEvent(
        FileTransferReceiveEvent('cancelled', 'transfer-2'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.transferIds, isEmpty);
    },
  );
}
