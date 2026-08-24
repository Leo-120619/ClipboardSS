import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import '../core/models.dart';

/// Desktop chrome for the Windows peer: system tray icon with recent clips,
/// close-to-tray window behavior, launch at login, and clean shutdown.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._(this._appState, this._copyToClipboard);

  static Future<void> init(
    AppState appState, {
    required Future<void> Function(ClipPayload clip) copyToClipboard,
  }) async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(420, 720),
      minimumSize: Size(360, 560),
      title: 'ClipboardSS',
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
    // Close hides to the tray; quitting happens from the tray menu.
    await windowManager.setPreventClose(true);

    launchAtStartup.setup(
      appName: 'ClipboardSS',
      appPath: Platform.resolvedExecutable,
    );

    final shell = DesktopShell._(appState, copyToClipboard);
    windowManager.addListener(shell);
    trayManager.addListener(shell);
    appState.addListener(shell._onAppStateChanged);
    await trayManager.setIcon('assets/app_icon.ico');
    await trayManager.setToolTip('ClipboardSS');
    await shell._rebuildMenu();
  }

  final AppState _appState;
  final Future<void> Function(ClipPayload clip) _copyToClipboard;
  bool _syncPaused = false;
  Timer? _menuRefresh;

  void _onAppStateChanged() {
    // Coalesce bursts of notifications into one menu rebuild.
    _menuRefresh?.cancel();
    _menuRefresh = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_rebuildMenu()),
    );
  }

  Future<void> _rebuildMenu() async {
    final bool startAtLogin;
    try {
      startAtLogin = await launchAtStartup.isEnabled();
    } catch (_) {
      return;
    }

    final recent = _appState.clips.take(5).toList();
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open ClipboardSS'),
          if (recent.isNotEmpty) MenuItem.separator(),
          for (final clip in recent)
            MenuItem(key: 'clip:${clip.id}', label: _clipLabel(clip)),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: 'pause',
            label: 'Pause sync',
            checked: _syncPaused,
          ),
          MenuItem.checkbox(
            key: 'login',
            label: 'Start at login',
            checked: startAtLogin,
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit ClipboardSS'),
        ],
      ),
    );
  }

  String _clipLabel(ClipPayload clip) {
    if (clip.type == ClipType.image) {
      return 'Image from ${clip.sourceDeviceName}';
    }
    final text = (clip.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 40 ? text : '${text.substring(0, 40)}…';
  }

  Future<void> _toggleWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
      await windowManager.focus();
    } else if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await _showAndFocus();
    }
  }

  Future<void> _showAndFocus() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    // A hide/show cycle can drop taskbar registration on Windows, causing a
    // later minimize to be parked on the desktop as a caption-only stub.
    await windowManager.setSkipTaskbar(false);
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_toggleWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null) return;
    switch (key) {
      case 'show':
        unawaited(_showAndFocus());
      case 'pause':
        unawaited(_togglePause());
      case 'login':
        unawaited(_toggleLaunchAtLogin());
      case 'quit':
        unawaited(_quit());
      default:
        if (key.startsWith('clip:')) {
          final id = key.substring('clip:'.length);
          final clip = _appState.clips.where((c) => c.id == id).firstOrNull;
          if (clip != null) {
            unawaited(_copyToClipboard(clip));
          }
        }
    }
  }

  Future<void> _togglePause() async {
    if (_syncPaused) {
      await _appState.resumeSyncServices();
      _syncPaused = false;
    } else {
      await _appState.pauseSyncServices();
      _syncPaused = true;
    }
    await _rebuildMenu();
  }

  Future<void> _toggleLaunchAtLogin() async {
    if (await launchAtStartup.isEnabled()) {
      await launchAtStartup.disable();
    } else {
      await launchAtStartup.enable();
    }
    await _rebuildMenu();
  }

  Future<void> _quit() async {
    _menuRefresh?.cancel();
    _appState.removeListener(_onAppStateChanged);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    _appState.dispose();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    unawaited(() async {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.hide();
    }());
  }

  @override
  void onWindowMinimize() {
    // Keep sync running while removing the minimized window from the desktop.
    unawaited(windowManager.hide());
  }
}
