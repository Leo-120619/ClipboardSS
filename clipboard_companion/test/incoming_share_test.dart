import 'package:clipboard_companion/core/incoming_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a native incoming share batch', () {
    final batch = IncomingShareBatch.fromMap({
      'id': 'batch-1',
      'skippedCount': 1,
      'attachments': [
        {
          'path': '/tmp/photo name.jpg',
          'name': 'photo name.jpg',
          'mimeType': 'image/jpeg',
          'size': 42,
        },
      ],
    });

    expect(batch.id, 'batch-1');
    expect(batch.skippedCount, 1);
    expect(batch.attachments, hasLength(1));
    expect(batch.attachments.single.name, 'photo name.jpg');
    expect(batch.attachments.single.mimeType, 'image/jpeg');
    expect(batch.attachments.single.size, 42);
  });

  test('uses safe defaults for optional native metadata', () {
    final batch = IncomingShareBatch.fromMap({
      'id': 'batch-2',
      'attachments': [
        {'path': '/tmp/file'},
      ],
    });

    expect(batch.skippedCount, 0);
    expect(batch.attachments.single.name, 'Shared file');
    expect(batch.attachments.single.mimeType, 'application/octet-stream');
    expect(batch.attachments.single.size, isNull);
  });
}
