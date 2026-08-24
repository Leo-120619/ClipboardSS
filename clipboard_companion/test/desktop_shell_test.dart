import 'package:clipboard_companion/core/app_state.dart';
import 'package:clipboard_companion/desktop/desktop_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');
  final binding = TestDefaultBinaryMessengerBinding.instance;

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(trayChannel, null);
  });

  test('minimizing hides the window in the notification area', () async {
    final windowCalls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (
      call,
    ) async {
      windowCalls.add(call.method);
      return switch (call.method) {
        'isFullScreen' ||
        'isMaximized' ||
        'isMinimized' ||
        'isVisible' => false,
        _ => null,
      };
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      trayChannel,
      (_) async => null,
    );

    final appState = AppState();
    final listenersBefore = windowManager.listeners.toSet();
    await DesktopShell.init(appState, copyToClipboard: (_) async {});
    await Future<void>.delayed(Duration.zero);
    final shell = windowManager.listeners.singleWhere(
      (listener) => !listenersBefore.contains(listener),
    );
    addTearDown(() {
      windowManager.removeListener(shell);
      trayManager.removeListener(shell as TrayListener);
      appState.dispose();
    });

    windowCalls.clear();
    shell.onWindowMinimize();
    await Future<void>.delayed(Duration.zero);

    expect(windowCalls, contains('hide'));
  });
}
