import 'models.dart';

/// Shared constants for the chunked file-transfer protocol.
/// Canonical spec: docs/wire-protocol.md ("File Transfer Protocol").
class FileTransferConstants {
  static const int chunkSize = 4 * 1024 * 1024;
  static const int maxChunkSize = 4 * 1024 * 1024;
  static const String fileKeySalt = 'ClipboardSS_FileKey';
  static const String transferIdHeader = 'X-Transfer-Id';
  static const String chunkIndexHeader = 'X-Chunk-Index';
  static const Duration idleTimeout = Duration(seconds: 60);

  /// Free space an offer must leave on the transfers volume: 500 MB (MiB,
  /// 524,288,000 bytes).
  static const int freeSpaceReserve = 500 * 1024 * 1024;

  /// Most concurrent receive sessions one source device may hold.
  static const int maxSessionsPerDevice = 8;

  /// How long a cancelled transfer id is remembered (chunks for it get 410).
  static const Duration cancelledRetention = Duration(seconds: 600);

  /// How long a sender waits for `/v1/file/finish`, which the receiver answers
  /// only after hashing the whole file: 1 s per 20 MiB, at least 30 s, at most
  /// 600 s (4 GiB -> 205 s).
  static Duration finishTimeout(int fileSize) {
    const perSecond = 20 * 1024 * 1024;
    final seconds = (fileSize < 0 ? 0 : fileSize + perSecond - 1) ~/ perSecond;
    return Duration(seconds: seconds.clamp(30, 600));
  }
}

String _iso8601(DateTime date) =>
    '${date.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// Inner JSON of `POST /v1/file/offer` (sealed in a [ClipEnvelope]).
class FileOfferPayload {
  final String transferId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String fileHash;
  final int chunkSize;
  final int chunkCount;
  final DateTime createdAt;
  final String sourceDeviceName;

  FileOfferPayload({
    required this.transferId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.fileHash,
    required this.chunkSize,
    required this.chunkCount,
    required this.createdAt,
    required this.sourceDeviceName,
  });

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'fileHash': fileHash,
    'chunkSize': chunkSize,
    'chunkCount': chunkCount,
    'createdAt': _iso8601(createdAt),
    'sourceDeviceName': sourceDeviceName,
  };

  factory FileOfferPayload.fromJson(Map<String, dynamic> json) =>
      FileOfferPayload(
        transferId: json['transferId'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        mimeType: json['mimeType'] as String,
        fileHash: json['fileHash'] as String,
        chunkSize: (json['chunkSize'] as num).toInt(),
        chunkCount: (json['chunkCount'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        sourceDeviceName: json['sourceDeviceName'] as String,
      );
}

class FileFinishPayload {
  final String transferId;
  FileFinishPayload(this.transferId);
  Map<String, dynamic> toJson() => {'transferId': transferId};
  factory FileFinishPayload.fromJson(Map<String, dynamic> json) =>
      FileFinishPayload(json['transferId'] as String);
}

class FileCancelPayload {
  final String transferId;
  FileCancelPayload(this.transferId);
  Map<String, dynamic> toJson() => {'transferId': transferId};
  factory FileCancelPayload.fromJson(Map<String, dynamic> json) =>
      FileCancelPayload(json['transferId'] as String);
}
