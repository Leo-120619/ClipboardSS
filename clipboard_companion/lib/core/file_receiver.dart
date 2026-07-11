import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';
import 'content_hasher.dart';
import 'crypto_utils.dart';
import 'file_transfer_crypto.dart';
import 'file_transfer_models.dart';
import 'models.dart';
import 'paired_device_store.dart';

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
  final Directory transfersDirectory;
  final Directory Function() destinationProvider;
  final DateTime Function() now;
  final Duration idleTimeout;

  final _sessions = <String, _Session>{};
  final _cancelled = <String>{};
  final _events = StreamController<FileTransferReceiveEvent>.broadcast();

  FileReceiver({
    required this.pairedStore,
    required this.transfersDirectory,
    required this.destinationProvider,
    DateTime Function()? now,
    this.idleTimeout = FileTransferConstants.idleTimeout,
  }) : now = now ?? DateTime.now;

  Stream<FileTransferReceiveEvent> get events => _events.stream;

  Future<void> dispose() async => _events.close();

  // MARK: - Offer

  Future<FileTransferResponse> handleOffer(ClipEnvelope envelope) async {
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key == null) return FileTransferResponse(401, {'status': 'unpaired'});

    FileOfferPayload offer;
    try {
      offer = FileOfferPayload.fromJson(
        await CryptoEnvelopeUtils.openJson(envelope, key),
      );
    } catch (_) {
      return FileTransferResponse(401, {'status': 'unpaired'});
    }
    if (!_validTransferId(offer.transferId)) {
      return FileTransferResponse(400, {'status': 'invalidId'});
    }
    if (!_validOffer(offer)) {
      return FileTransferResponse(400, {'status': 'invalidOffer'});
    }

    if (_sessions.containsKey(offer.transferId)) {
      return FileTransferResponse(409, {'status': 'duplicate'});
    }

    try {
      await transfersDirectory.create(recursive: true);
      final tempFile = File(
        '${transfersDirectory.path}/${offer.transferId}.part',
      );
      final raf = await tempFile.open(mode: FileMode.write);
      final fileKey = await FileTransferCrypto.deriveFileKey(
        key,
        offer.transferId,
      );
      _sessions[offer.transferId] = _Session(
        offer: offer,
        sourceDeviceId: envelope.sourceDeviceId,
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
      return FileTransferResponse(400, {'status': 'error'});
    }
  }

  // MARK: - Chunk

  Future<FileTransferResponse> handleChunk(
    String transferId,
    int chunkIndex,
    List<int> body,
  ) async {
    if (_cancelled.contains(transferId)) {
      return FileTransferResponse(410, {'status': 'cancelled'});
    }
    final session = _sessions[transferId];
    if (session == null)
      return FileTransferResponse(404, {'status': 'unknown'});

    if (chunkIndex < 0 || chunkIndex >= session.offer.chunkCount) {
      await _teardown(transferId, 'bad chunk index');
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
      await _teardown(transferId, 'chunk authentication failed');
      return FileTransferResponse(400, {'status': 'authFailed'});
    }
    final expectedSize = chunkIndex == session.offer.chunkCount - 1
        ? session.offer.fileSize - chunkIndex * session.offer.chunkSize
        : session.offer.chunkSize;
    if (plaintext.length != expectedSize) {
      await _teardown(transferId, 'bad chunk size');
      return FileTransferResponse(400, {'status': 'badSize'});
    }

    if (session.received.contains(chunkIndex)) {
      session.lastActivity = now();
      return FileTransferResponse(200, {
        'status': 'ok',
        'received': session.received.length,
      });
    }

    try {
      await session.raf.setPosition(chunkIndex * session.offer.chunkSize);
      await session.raf.writeFrom(plaintext);
    } catch (_) {
      await _teardown(transferId, 'write failed');
      return FileTransferResponse(400, {'status': 'writeFailed'});
    }

    session.received.add(chunkIndex);
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
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key == null) return FileTransferResponse(401, {'status': 'unpaired'});

    FileFinishPayload finish;
    try {
      finish = FileFinishPayload.fromJson(
        await CryptoEnvelopeUtils.openJson(envelope, key),
      );
    } catch (_) {
      return FileTransferResponse(401, {'status': 'unpaired'});
    }

    final session = _sessions[finish.transferId];
    if (session == null)
      return FileTransferResponse(404, {'status': 'unknown'});

    if (session.received.length != session.offer.chunkCount) {
      return FileTransferResponse(409, {'status': 'incomplete'});
    }

    await session.raf.close();

    final tempPath = session.tempFile.path;
    final computed = await Isolate.run(
      () => ContentHasher.fileHashOfFile(File(tempPath)),
    );
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
    final key = await pairedStore.getKey(envelope.sourceDeviceId);
    if (key != null) {
      try {
        final cancel = FileCancelPayload.fromJson(
          await CryptoEnvelopeUtils.openJson(envelope, key),
        );
        _cancelled.add(cancel.transferId);
        final session = _sessions[cancel.transferId];
        if (session != null) {
          await _destroy(cancel.transferId, session);
          _emit(FileTransferReceiveEvent('cancelled', cancel.transferId));
        }
      } catch (_) {
        // Idempotent: ignore undecodable cancels.
      }
    }
    return FileTransferResponse(200, {'status': 'cancelled'});
  }

  // MARK: - Garbage collection

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
  }

  // MARK: - Internals

  Future<void> _teardown(String transferId, String reason) async {
    final session = _sessions[transferId];
    if (session != null) await _destroy(transferId, session);
    _emit(FileTransferReceiveEvent('failed', transferId, reason: reason));
  }

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
