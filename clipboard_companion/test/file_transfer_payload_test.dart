import 'package:clipboard_companion/core/file_transfer_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offer payload has exactly the spec field names', () {
    final offer = FileOfferPayload(
      transferId: '6f9619ff-8b86-d011-b42d-00c04fc964ff',
      fileName: 'movie.mp4',
      fileSize: 157286400,
      mimeType: 'video/mp4',
      fileHash: 'abc',
      chunkSize: 4194304,
      chunkCount: 38,
      createdAt: DateTime.utc(1970, 1, 1),
      sourceDeviceName: 'Mac',
    );
    final json = offer.toJson();
    expect(json.keys.toSet(), {
      'transferId',
      'fileName',
      'fileSize',
      'mimeType',
      'fileHash',
      'chunkSize',
      'chunkCount',
      'createdAt',
      'sourceDeviceName',
    });
    expect(json['transferId'], '6f9619ff-8b86-d011-b42d-00c04fc964ff');
    expect(json['chunkSize'], 4194304);
    expect(json['createdAt'], '1970-01-01T00:00:00Z');
  });

  test('finish and cancel payloads carry only transferId', () {
    expect(FileFinishPayload('t').toJson().keys.toSet(), {'transferId'});
    expect(FileCancelPayload('t').toJson().keys.toSet(), {'transferId'});
  });

  test('offer round-trips through JSON', () {
    final offer = FileOfferPayload(
      transferId: 't',
      fileName: 'a.bin',
      fileSize: 10,
      mimeType: 'application/octet-stream',
      fileHash: 'h',
      chunkSize: 4194304,
      chunkCount: 1,
      createdAt: DateTime.utc(2026, 7, 10, 12),
      sourceDeviceName: 'Mac',
    );
    final decoded = FileOfferPayload.fromJson(offer.toJson());
    expect(decoded.transferId, offer.transferId);
    expect(decoded.fileSize, offer.fileSize);
    expect(decoded.chunkCount, offer.chunkCount);
    expect(decoded.createdAt, offer.createdAt);
  });
}
