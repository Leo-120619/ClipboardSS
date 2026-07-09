import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/content_hasher.dart';
import '../core/models.dart';
import 'windows_clipboard.dart';

/// Watches the Windows clipboard and auto-broadcasts new content to paired
/// devices; writes incoming clips back to the clipboard.
///
/// Loop prevention mirrors the Mac app (AppModel.refresh's
/// lastBroadcastClipID guard + ClipStore content-hash dedup): the hash of
/// whatever this service last wrote to the clipboard is recorded before the
/// write, so the resulting WM_CLIPBOARDUPDATE is ignored, and content that
/// matches the newest stored clip is never re-broadcast.
class ClipboardSyncService {
  ClipboardSyncService({
    required this.clipboard,
    required this.deviceName,
    required this.broadcast,
    required this.topClipHash,
    this.debounce = const Duration(milliseconds: 300),
  });

  final WindowsClipboard clipboard;
  final String deviceName;
  final Future<void> Function(ClipPayload clip) broadcast;

  /// Content hash of the newest stored clip, used for duplicate suppression.
  final String? Function() topClipHash;
  final Duration debounce;

  StreamSubscription<void>? _subscription;
  Timer? _pending;
  String? _lastWrittenHash;

  void start() {
    _subscription ??= clipboard.onChanged.listen((_) {
      // Coalesce bursts: apps with delayed rendering fire several
      // WM_CLIPBOARDUPDATEs per copy.
      _pending?.cancel();
      _pending = Timer(debounce, () => unawaited(processClipboardChange()));
    });
  }

  /// Reads the clipboard and broadcasts its content unless it is something
  /// this service wrote or a duplicate of the newest clip.
  @visibleForTesting
  Future<void> processClipboardChange() async {
    final WindowsClipboardContent? content;
    try {
      content = await clipboard.read();
    } catch (e) {
      debugPrint('Clipboard read failed: $e');
      return;
    }
    if (content == null) return;

    final text = content.text;
    final png = content.pngBytes;
    final hash = text != null
        ? ContentHasher.textHash(text)
        : ContentHasher.imageHash(png!);
    if (hash == _lastWrittenHash || hash == topClipHash()) return;

    final clip = text != null
        ? ClipPayload(
            id: const Uuid().v4(),
            type: ClipType.text,
            createdAt: DateTime.now(),
            text: text,
            contentHash: hash,
            sourceDeviceName: deviceName,
          )
        : ClipPayload(
            id: const Uuid().v4(),
            type: ClipType.image,
            createdAt: DateTime.now(),
            imageBase64: base64Encode(png!),
            imageExtension: 'png',
            contentHash: hash,
            sourceDeviceName: deviceName,
          );
    await broadcast(clip);
  }

  /// Writes an incoming clip to the Windows clipboard without re-broadcasting
  /// it. Also used for the history "copy" action.
  Future<void> writeIncoming(ClipPayload payload) async {
    final text = payload.text;
    if (payload.type == ClipType.text && text != null) {
      _lastWrittenHash = ContentHasher.textHash(text);
      await clipboard.writeText(text);
      return;
    }

    final base64 = payload.imageBase64;
    if (base64 == null || base64.isEmpty) return;
    final Uint8List bytes;
    try {
      bytes = base64Decode(base64);
    } on FormatException {
      return;
    }
    _lastWrittenHash = ContentHasher.imageHash(bytes);
    await clipboard.writeImage(bytes);
  }

  void dispose() {
    _pending?.cancel();
    _subscription?.cancel();
    _subscription = null;
  }
}
