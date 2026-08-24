import 'package:flutter/services.dart';

/// Android-only bridge for publishing received files to the public Downloads
/// collection and showing that location in the system file manager.
class AndroidDownloads {
  static const _defaultChannel = MethodChannel(
    'clipboard_companion/android_downloads',
  );

  final MethodChannel _channel;

  AndroidDownloads({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  Future<void> publish({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    await _channel.invokeMethod<void>('publishReceivedFile', {
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }

  Future<bool> openDownloads() async =>
      await _channel.invokeMethod<bool>('openDownloads') ?? false;
}
