enum TransferDirection { sending, receiving }

enum TransferStatus {
  inProgress,
  completed,

  /// Sent, but the receiver did not confirm in time; it may still have saved
  /// the file.
  unconfirmed,
  failed,
  cancelled,
}

const unconfirmedSendMessage =
    'The other device did not confirm in time. Check whether the file arrived there.';

/// UI-facing state for a single in-flight or finished file transfer.
class FileTransferUiState {
  final String id;

  /// Stable key: the protocol `transferId` for receives, or the UI id for sends.
  final String key;
  final String fileName;
  final TransferDirection direction;
  double progress;
  TransferStatus status;
  String? path;
  String? reason;

  FileTransferUiState({
    required this.id,
    required this.key,
    required this.fileName,
    required this.direction,
    this.progress = 0,
    this.status = TransferStatus.inProgress,
    this.path,
    this.reason,
  });

  bool get isActive => status == TransferStatus.inProgress;
}

/// Simple cancellation flag polled by `FileSender.sendFile(isCancelled:)`.
class TransferCancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}
