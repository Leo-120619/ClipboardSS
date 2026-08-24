import 'dart:io';

class SharedAttachment {
  final String path;
  final String name;
  final String mimeType;
  final int? size;

  const SharedAttachment({
    required this.path,
    required this.name,
    required this.mimeType,
    this.size,
  });

  factory SharedAttachment.fromMap(Map<Object?, Object?> map) {
    return SharedAttachment(
      path: map['path'] as String,
      name: map['name'] as String? ?? 'Shared file',
      mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
      size: map['size'] as int?,
    );
  }

  File get file => File(path);
}

class IncomingShareBatch {
  final String id;
  final List<SharedAttachment> attachments;
  final int skippedCount;

  const IncomingShareBatch({
    required this.id,
    required this.attachments,
    this.skippedCount = 0,
  });

  factory IncomingShareBatch.fromMap(Map<Object?, Object?> map) {
    final raw = map['attachments'] as List<Object?>? ?? const [];
    return IncomingShareBatch(
      id: map['id'] as String,
      attachments: raw
          .whereType<Map<Object?, Object?>>()
          .map(SharedAttachment.fromMap)
          .toList(growable: false),
      skippedCount: map['skippedCount'] as int? ?? 0,
    );
  }
}
