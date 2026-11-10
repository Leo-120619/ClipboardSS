import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'content_hasher.dart';
import 'crypto_utils.dart';
import 'file_transfer_crypto.dart';
import 'file_transfer_models.dart';
import 'models.dart';
import 'paired_device_store.dart';
import 'replay_guard.dart';
import 'volume_free_space.dart';

/// UI-facing event emitted as a transfer progresses on the receiving side.
class FileTransferReceiveEvent {
  final String type; // started | progress | completed | failed | cancelled
  final String transferId;
  final String? fileName;
  final int received;
  final int total;
  final String? path;
  final String? reason;

  FileTransferReceiveEvent(
    this.type,
    this.transferId, {
    this.fileName,
    this.received = 0,
    this.total = 0,
    this.path,
    this.reason,
  });
}

/// Response returned by the receiver for a `/v1/file/*` request, translated into a shelf
/// `Response` by the server layer.
class FileTransferResponse {
  final int statusCode;
  final Map<String, dynamic> body;
  FileTransferResponse(this.statusCode, this.body);
}

class _Session {
  final FileOfferPayload offer;
  final String sourceDeviceId;
  final SecretKey fileKey;
  final File tempFile;
  final RandomAccessFile raf;
  final Set<int> received = {};

  /// Plaintext bytes of the distinct chunks already on disk.
  int bytesWritten = 0;
  DateTime lastActivity;

  _Session({
    required this.offer,
    required this.sourceDeviceId,
    required this.fileKey,
    required this.tempFile,
    required this.raf,
    required this.lastActivity,
  });
}

/// Receives chunked file transfers. Sessions live in memory; chunk plaintext is written to
/// a `.part` temp file at `index * chunkSize` offsets; sessions GC after an idle timeout.
class FileReceiver {
  final PairedDeviceStore pairedStore;

  /// This device's id: the recipient every inbound envelope must be sealed for.
  final String localDeviceId;
  final Directory transfersDirectory;
  final Directory Function() destinationProvider;
  final DateTime Function() now;
  final Duration idleTimeout;

  /// Shared with the clip endpoint in production (one guard per process).
  final ReplayGuard replayGuard;

  /// Bytes available on the transfers volume.
  final Future<int> Function() freeSpaceProvider;

  /// Writes one chunk's plaintext at a byte offset (a seam for tests).
  final Future<void> Function(RandomAccessFile raf, int offset, List<int> bytes)
  chunkWriter;

  final _sessions = <String, _Session>{};

  /// Offers past validation whose session is still being set up: holding the id
  /// here before the first `await` keeps a concurrent identical offer from
  /// opening (and leaking) a second handle.
  final _pendingOffers = <String, ({String source, int size})>{};

  /// Cancelled transfer id -> when it was cancelled; pruned after
  /// [FileTransferConstants.cancelledRetention].
  final _cancelled = <String, DateTime>{};
  final _events = StreamController<FileTransferReceiveEvent>.broadcast();

  FileReceiver({
    required this.pairedStore,
    required String localDeviceId,
    required this.transfersDirectory,
    required this.destinationProvider,
    DateTime Function()? now,
    this.idleTimeout = FileTransferConstants.idleTimeout,
    ReplayGuard? replayGuard,
    Future<int> Function()? freeSpaceProvider,
    Future<void> Function(RandomAccessFile raf, int offset, List<int> bytes)?
    chunkWriter,
  }) : localDeviceId = canonicalDeviceId(localDeviceId),
       now = now ?? DateTime.now,
       replayGuard = replayGuard ?? ReplayGuard(),
       freeSpaceProvider =
           freeSpaceProvider ?? (() => volumeFreeSpace(transfersDirectory)),
       chunkWriter = chunkWriter ?? _defaultChunkWriter;

  static Future<void> _defaultChunkWriter(
    RandomAccessFile raf,
    int offset,
    List<int> bytes,
  ) async {
    await raf.setPosition(offset);
    await raf.writeFrom(bytes);
  }

  Stream<FileTransferReceiveEvent> get events => _events.stream;

  /// Active sessions (test hook).
  @visibleForTesting
  int get activeSessionCount => _sessions.length;

  /// Remembered cancelled ids (test hook for pruning).
  @visibleForTesting
  int get cancelledTransferCount => _cancelled.length;

  Future<void> dispose() async => _events.close();

  FileTransferResponse _upgradeRequired() => FileTransferResponse(426, {
    'status': 'upgradeRequired',
    'minVersion': wireProtocolVersion,
  });

  /// Runs only after a successful AEAD open, before any session change.
  FileTransferResponse? _replayRejection(
    ClipEnvelope envelope,
    Map<String, dynamic> json,
  ) {
    final rejection = replayRejection(
      replayGuard.check(
        sourceDeviceId: envelope.sourceDeviceId,
        nonce: envelope.nonce,
        sentAt: sentAtOf(json),
      ),
    );
    if (rejection == null) return null;
    final (status, body) = rejection;
    return FileTransferResponse(status, body);
  }

  // MARK: - Offer

  Future<FileTransferResponse> handleOffer(ClipEnvelope envelope) async {
    if (envelope.v != wireProtocolVersion) return _upgradeRequired();
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key == null) return FileTransferResponse(401, {'status': 'unpaired'});
    if (!pairedStore.isConnected(envelope.sourceDeviceId)) {
      return FileTransferResponse(401, {'status': 'paused'});
    }

    final Map<String, dynamic> json;
    FileOfferPayload offer;
    try {
      json = await CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.fileOffer,
        recipientDeviceId: localDeviceId,
        pairKey: key,
      );
      offer = FileOfferPayload.fromJson(json);
    } catch (_) {
      return FileTransferResponse(401, {'status': 'unpaired'});
    }
    final rejected = _replayRejection(envelope, json);
    if (rejected != null) return rejected;
    if (!_validTransferId(offer.transferId)) {
      return FileTransferResponse(400, {'status': 'invalidId'});
    }
    if (!_validOffer(offer)) {
      return FileTransferResponse(400, {'status': 'invalidOffer'});
    }

    if (_sessions.containsKey(offer.transferId) ||
        _pendingOffers.containsKey(offer.transferId)) {
      return FileTransferResponse(409, {'status': 'duplicate'});
    }
    final source = envelope.sourceDeviceId;
    final activeForDevice =
        _sessions.values.where((s) => s.sourceDeviceId == source).length +
        _pendingOffers.values.where((p) => p.source == source).length;
    if (activeForDevice >= FileTransferConstants.maxSessionsPerDevice) {
      return FileTransferResponse(429, {'status': 'tooManyTransfers'});
    }

    _pendingOffers[offer.transferId] = (source: source, size: offer.fileSize);
    final tempFile = File(
      '${transfersDirectory.path}/${offer.transferId}.part',
    );
    RandomAccessFile? raf;
    try {
      final freeSpace = await freeSpaceProvider();
      // Space still owed to active (and other in-flight) sessions counts as
      // used: nothing is preallocated.
      var committed = 0;
      for (final s in _sessions.values) {
        committed += s.offer.fileSize - s.bytesWritten;
      }
      for (final entry in _pendingOffers.entries) {
        if (entry.key != offer.transferId) committed += entry.value.size;
      }
      if (offer.fileSize >
          freeSpace - committed - FileTransferConstants.freeSpaceReserve) {
        return FileTransferResponse(400, {'status': 'tooLarge'});
      }
      await transfersDirectory.create(recursive: true);
      raf = await tempFile.open(mode: FileMode.write);
      final fileKey = await FileTransferCrypto.deriveFileKey(
        key,
        offer.transferId,
      );
      _sessions[offer.transferId] = _Session(
        offer: offer,
        sourceDeviceId: source,
        fileKey: fileKey,
        tempFile: tempFile,
        raf: raf,
        lastActivity: now(),
      );
      _cancelled.remove(offer.transferId);
      _emit(
        FileTransferReceiveEvent(
          'started',
          offer.transferId,
          fileName: offer.fileName,
          total: offer.chunkCount,
        ),
      );
      return FileTransferResponse(200, {'status': 'ready'});
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      return FileTransferResponse(400, {'status': 'error'});
    } finally {
      _pendingOffers.remove(offer.transferId);
    }
  }

  // MARK: - Chunk

  /// Chunks are unauthenticated at the HTTP layer (anyone who sees
  /// `X-Transfer-Id` can post one), so a rejected chunk never touches the
  /// session: it stays intact for the real sender.
  Future<FileTransferResponse> handleChunk(
    String transferId,
    int chunkIndex,
    List<int> body,
  ) async {
    if (_cancelled.containsKey(transferId)) {
      return FileTransferResponse(410, {'status': 'cancelled'});
    }
    final session = _sessions[transferId];
    if (session == null)
      return FileTransferResponse(404, {'status': 'unknown'});

    if (chunkIndex < 0 || chunkIndex >= session.offer.chunkCount) {
      return FileTransferResponse(400, {'status': 'badIndex'});
    }

    List<int> plaintext;
    try {
      plaintext = await FileTransferCrypto.openChunk(
        body,
        session.fileKey,
        chunkIndex,
      );
    } catch (_) {
      return FileTransferResponse(400, {'status': 'authFailed'});
    }
    final expectedSize = chunkIndex == session.offer.chunkCount - 1
        ? session.offer.fileSize - chunkIndex * session.offer.chunkSize
        : session.offer.chunkSize;
    if (plaintext.length != expectedSize) {
      return FileTransferResponse(400, {'status': 'badSize'});
    }

    if (session.received.contains(chunkIndex)) {
      session.lastActivity = now();
      return FileTransferResponse(200, {
        'status': 'ok',
        'received': session.received.length,
      });
    }

    // The index counts as received only once its bytes are on disk; a retry
    // rewrites it.
    try {
      await chunkWriter(
        session.raf,
        chunkIndex * session.offer.chunkSize,
        plaintext,
      );
    } catch (_) {
      return FileTransferResponse(400, {'status': 'writeFailed'});
    }

    // A concurrent identical chunk may have landed during the awaited write.
    if (session.received.add(chunkIndex)) {
      session.bytesWritten += plaintext.length;
    }
    session.lastActivity = now();
    _emit(
      FileTransferReceiveEvent(
        'progress',
        transferId,
        received: session.received.length,
        total: session.offer.chunkCount,
      ),
    );
    return FileTransferResponse(200, {
      'status': 'ok',
      'received': session.received.length,
    });
  }

  // MARK: - Finish

  Future<FileTransferResponse> handleFinish(ClipEnvelope envelope) async {
    if (envelope.v != wireProtocolVersion) return _upgradeRequired();
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key == null) return FileTransferResponse(401, {'status': 'unpaired'});
    if (!pairedStore.isConnected(envelope.sourceDeviceId)) {
      return FileTransferResponse(401, {'status': 'paused'});
    }

    final Map<String, dynamic> json;
    FileFinishPayload finish;
    try {
      json = await CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.fileFinish,
        recipientDeviceId: localDeviceId,
        pairKey: key,
      );
      finish = FileFinishPayload.fromJson(json);
    } catch (_) {
      return FileTransferResponse(401, {'status': 'unpaired'});
    }
    final rejected = _replayRejection(envelope, json);
    if (rejected != null) return rejected;

    // Another paired device must not learn of, or finish, this device's
    // transfer.
    final session = _sessions[finish.transferId];
    if (session == null || session.sourceDeviceId != envelope.sourceDeviceId) {
      return FileTransferResponse(404, {'status': 'unknown'});
    }

    if (session.received.length != session.offer.chunkCount) {
      return FileTransferResponse(409, {'status': 'incomplete'});
    }

    final String computed;
    try {
      await session.raf.close();
      final tempPath = session.tempFile.path;
      computed = await Isolate.run(
        () => ContentHasher.fileHashOfFile(File(tempPath)),
      );
    } catch (_) {
      await _destroy(finish.transferId, session);
      _emit(
        FileTransferReceiveEvent(
          'failed',
          finish.transferId,
          reason: 'hash read failed',
        ),
      );
      return FileTransferResponse(422, {'status': 'error'});
    }
    if (computed != session.offer.fileHash) {
      await _destroy(finish.transferId, session);
      _emit(
        FileTransferReceiveEvent(
          'failed',
          finish.transferId,
          reason: 'hash mismatch',
        ),
      );
      return FileTransferResponse(422, {'status': 'hashMismatch'});
    }

    try {
      final destination = await _finalize(session);
      _sessions.remove(finish.transferId);
      _emit(
        FileTransferReceiveEvent(
          'completed',
          finish.transferId,
          path: destination.path,
        ),
      );
      return FileTransferResponse(200, {
        'status': 'complete',
        'fileName': _basename(destination.path),
      });
    } catch (_) {
      await _destroy(finish.transferId, session);
      _emit(
        FileTransferReceiveEvent(
          'failed',
          finish.transferId,
          reason: 'finalize failed',
        ),
      );
      return FileTransferResponse(422, {'status': 'error'});
    }
  }

  // MARK: - Cancel

  Future<FileTransferResponse> handleCancel(ClipEnvelope envelope) async {
    if (envelope.v != wireProtocolVersion) return _upgradeRequired();
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key != null) {
      if (!pairedStore.isConnected(envelope.sourceDeviceId)) {
        return FileTransferResponse(401, {'status': 'paused'});
      }
      final Map<String, dynamic> json;
      final FileCancelPayload cancel;
      try {
        json = await CryptoEnvelopeUtils.openJson(
          envelope,
          purpose: EnvelopePurpose.fileCancel,
          recipientDeviceId: localDeviceId,
          pairKey: key,
        );
        cancel = FileCancelPayload.fromJson(json);
      } catch (_) {
        // Idempotent: ignore undecodable cancels.
        return FileTransferResponse(200, {'status': 'cancelled'});
      }
      final rejected = _replayRejection(envelope, json);
      if (rejected != null) return rejected;
      final session = _sessions[cancel.transferId];
      if (session != null &&
          session.sourceDeviceId != envelope.sourceDeviceId) {
        return FileTransferResponse(404, {'status': 'unknown'});
      }
      try {
        _pruneCancelled();
        _cancelled[cancel.transferId] = now();
        if (session != null) {
          await _destroy(cancel.transferId, session);
          _emit(FileTransferReceiveEvent('cancelled', cancel.transferId));
        }
      } catch (_) {
        // Best effort: cancel stays idempotent even if cleanup fails.
      }
    }
    return FileTransferResponse(200, {'status': 'cancelled'});
  }

  // MARK: - Garbage collection

  /// Drops sessions idle longer than [idleTimeout], deleting their temp files,
  /// and forgets cancelled ids older than the cancelled-id retention.
  Future<void> garbageCollect() async {
    final cutoff = now().subtract(idleTimeout);
    final stale = _sessions.entries
        .where((e) => e.value.lastActivity.isBefore(cutoff))
        .toList();
    for (final entry in stale) {
      await _destroy(entry.key, entry.value);
      _emit(
        FileTransferReceiveEvent('failed', entry.key, reason: 'idle timeout'),
      );
    }
    _pruneCancelled();
  }

  void _pruneCancelled() {
    final cutoff = now().subtract(FileTransferConstants.cancelledRetention);
    _cancelled.removeWhere((_, cancelledAt) => !cancelledAt.isAfter(cutoff));
  }

  // MARK: - Internals

  Future<void> _destroy(String transferId, _Session session) async {
    try {
      await session.raf.close();
    } catch (_) {}
    try {
      if (await session.tempFile.exists()) await session.tempFile.delete();
    } catch (_) {}
    _sessions.remove(transferId);
  }

  Future<File> _finalize(_Session session) async {
    final dir = destinationProvider();
    await dir.create(recursive: true);
    final safeName = _basename(session.offer.fileName);
    final destination = _uniqueDestination(
      dir,
      safeName.isEmpty ? 'download' : safeName,
    );
    try {
      return await session.tempFile.rename(destination.path);
    } catch (_) {
      // Cross-volume fallback.
      final copied = await session.tempFile.copy(destination.path);
      await session.tempFile.delete();
      return copied;
    }
  }

  bool _validTransferId(String transferId) =>
      RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(transferId);

  bool _validOffer(FileOfferPayload offer) {
    if (offer.chunkSize <= 0 ||
        offer.chunkSize > FileTransferConstants.maxChunkSize ||
        offer.fileSize < 0) {
      return false;
    }
    final expectedCount = offer.fileSize == 0
        ? 0
        : (offer.fileSize + offer.chunkSize - 1) ~/ offer.chunkSize;
    return offer.chunkCount == expectedCount;
  }

  File _uniqueDestination(Directory dir, String fileName) {
    final candidate = File('${dir.path}/$fileName');
    if (!candidate.existsSync()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var i = 1;
    while (true) {
      final url = File('${dir.path}/$base ($i)$ext');
      if (!url.existsSync()) return url;
      i++;
    }
  }

  String _basename(String path) => path.split('/').last.split('\\').last;

  void _emit(FileTransferReceiveEvent event) {
    if (_events.hasListener) _events.add(event);
  }
}
