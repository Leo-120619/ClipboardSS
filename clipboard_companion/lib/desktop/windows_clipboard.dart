import 'dart:async';

import 'package:flutter/services.dart';

import 'dib_codec.dart';

/// A snapshot of the Windows clipboard: either [text] or PNG [pngBytes].
class WindowsClipboardContent {
  final String? text;
  final Uint8List? pngBytes;

  const WindowsClipboardContent.text(String this.text) : pngBytes = null;
  const WindowsClipboardContent.image(Uint8List this.pngBytes) : text = null;

  bool get isText => text != null;
}

/// Interface over the native Win32 clipboard, backed by the
/// `clipboard_companion/win_clipboard` method channel. Abstract so tests can
/// substitute a fake.
abstract class WindowsClipboard {
  /// Fires whenever the OS clipboard changes (WM_CLIPBOARDUPDATE).
  Stream<void> get onChanged;

  Future<WindowsClipboardContent?> read();
  Future<void> writeText(String text);

  /// Writes an image (PNG, JPEG, ...) to the clipboard as PNG + CF_DIB.
  Future<void> writeImage(Uint8List imageBytes);
}

class MethodChannelWindowsClipboard implements WindowsClipboard {
  static const MethodChannel _channel = MethodChannel(
    'clipboard_companion/win_clipboard',
  );

  final StreamController<void> _changes = StreamController<void>.broadcast();

  MethodChannelWindowsClipboard() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'clipboardChanged') {
        _changes.add(null);
      }
    });
  }

  @override
  Stream<void> get onChanged => _changes.stream;

  @override
  Future<WindowsClipboardContent?> read() async {
    final map = await _channel.invokeMapMethod<String, dynamic>(
      'readClipboard',
    );
    if (map == null) return null;

    if (map['type'] == 'text') {
      final text = map['text'] as String?;
      return text == null ? null : WindowsClipboardContent.text(text);
    }

    final bytes = map['bytes'] as Uint8List?;
    if (bytes == null || bytes.isEmpty) return null;
    final png = map['format'] == 'png' ? bytes : DibCodec.dibToPng(bytes);
    return png == null ? null : WindowsClipboardContent.image(png);
  }

  @override
  Future<void> writeText(String text) {
    return _channel.invokeMethod<void>('writeText', {'text': text});
  }

  @override
  Future<void> writeImage(Uint8List imageBytes) async {
    final png = DibCodec.toPng(imageBytes);
    final dib = DibCodec.imageToDib(imageBytes);
    if (png == null || dib == null) {
      throw const FormatException('Could not decode image for clipboard');
    }
    await _channel.invokeMethod<void>('writeImage', {'png': png, 'dib': dib});
  }
}
