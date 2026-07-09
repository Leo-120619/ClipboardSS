import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clipboard_companion/core/content_hasher.dart';
import 'package:clipboard_companion/core/models.dart';
import 'package:clipboard_companion/desktop/clipboard_sync_service.dart';
import 'package:clipboard_companion/desktop/windows_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class FakeWindowsClipboard implements WindowsClipboard {
  final StreamController<void> changes = StreamController<void>.broadcast();
  WindowsClipboardContent? content;
  final List<String> writtenTexts = [];
  final List<Uint8List> writtenImages = [];

  @override
  Stream<void> get onChanged => changes.stream;

  @override
  Future<WindowsClipboardContent?> read() async => content;

  @override
  Future<void> writeText(String text) async {
    writtenTexts.add(text);
    content = WindowsClipboardContent.text(text);
  }

  @override
  Future<void> writeImage(Uint8List imageBytes) async {
    writtenImages.add(imageBytes);
    content = WindowsClipboardContent.image(imageBytes);
  }
}

void main() {
  late FakeWindowsClipboard clipboard;
  late List<ClipPayload> broadcasts;
  List<ClipPayload> clips = [];

  ClipboardSyncService makeService({
    Duration debounce = const Duration(milliseconds: 1),
  }) {
    return ClipboardSyncService(
      clipboard: clipboard,
      deviceName: 'Test PC',
      broadcast: (clip) async {
        broadcasts.add(clip);
        clips.insert(0, clip);
      },
      topClipHash: () => clips.isEmpty ? null : clips.first.contentHash,
      debounce: debounce,
    );
  }

  setUp(() {
    clipboard = FakeWindowsClipboard();
    broadcasts = [];
    clips = [];
  });

  test('new clipboard text is broadcast as a text clip', () async {
    final service = makeService();
    clipboard.content = const WindowsClipboardContent.text('hello');

    await service.processClipboardChange();

    expect(broadcasts, hasLength(1));
    expect(broadcasts.single.type, ClipType.text);
    expect(broadcasts.single.text, 'hello');
    expect(broadcasts.single.contentHash, ContentHasher.textHash('hello'));
    expect(broadcasts.single.sourceDeviceName, 'Test PC');
  });

  test('content written by writeIncoming is not re-broadcast', () async {
    final service = makeService();
    final incoming = ClipPayload(
      id: 'in-1',
      type: ClipType.text,
      createdAt: DateTime.now(),
      text: 'from mac',
      contentHash: ContentHasher.textHash('from mac'),
      sourceDeviceName: 'Mac',
    );

    await service.writeIncoming(incoming);
    expect(clipboard.writtenTexts, ['from mac']);

    // The write triggers WM_CLIPBOARDUPDATE -> processClipboardChange.
    await service.processClipboardChange();
    expect(broadcasts, isEmpty);
  });

  test('content matching the newest stored clip is not re-broadcast',
      () async {
    final service = makeService();
    clipboard.content = const WindowsClipboardContent.text('dup');

    await service.processClipboardChange();
    expect(broadcasts, hasLength(1));

    // Same content copied again: hash matches the top clip.
    await service.processClipboardChange();
    expect(broadcasts, hasLength(1));
  });

  test('image clipboard content is broadcast as a PNG clip', () async {
    final service = makeService();
    final png = img.encodePng(img.Image(width: 2, height: 2));
    clipboard.content = WindowsClipboardContent.image(png);

    await service.processClipboardChange();

    expect(broadcasts, hasLength(1));
    expect(broadcasts.single.type, ClipType.image);
    expect(broadcasts.single.imageExtension, 'png');
    expect(base64Decode(broadcasts.single.imageBase64!), png);
    expect(broadcasts.single.contentHash, ContentHasher.imageHash(png));
  });

  test('incoming image clips are written to the clipboard and suppressed',
      () async {
    final service = makeService();
    final png = img.encodePng(img.Image(width: 2, height: 2));
    final incoming = ClipPayload(
      id: 'in-2',
      type: ClipType.image,
      createdAt: DateTime.now(),
      imageBase64: base64Encode(png),
      imageExtension: 'png',
      contentHash: ContentHasher.imageHash(png),
      sourceDeviceName: 'Mac',
    );

    await service.writeIncoming(incoming);
    expect(clipboard.writtenImages, hasLength(1));

    await service.processClipboardChange();
    expect(broadcasts, isEmpty);
  });

  test('change events are debounced into one read', () async {
    final service = makeService(debounce: const Duration(milliseconds: 20));
    service.start();
    clipboard.content = const WindowsClipboardContent.text('burst');

    clipboard.changes.add(null);
    clipboard.changes.add(null);
    clipboard.changes.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(broadcasts, hasLength(1));
    service.dispose();
  });

  test('empty clipboard reads are ignored', () async {
    final service = makeService();
    clipboard.content = null;

    await service.processClipboardChange();
    expect(broadcasts, isEmpty);
  });
}
