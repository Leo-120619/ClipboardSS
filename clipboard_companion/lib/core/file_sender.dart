import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'content_hasher.dart';
import 'crypto_utils.dart';
import 'file_transfer_crypto.dart';
import 'file_transfer_models.dart';
import 'models.dart';
import 'paired_device_store.dart';

class FileSendException implements Exception {
  final String message;
  FileSendException(this.message);
  @override
  String toString() => 'FileSendException: $message';
}

class FileSendCancelledException implements Exception {}

/// A request got no answer within its timeout.
class _RequestTimeoutException extends FileSendException {
  _RequestTimeoutException(super.message);
}

/// The peer runs another wire protocol version (advertised, or answered 426).
class FileSendNeedsUpdateException extends FileSendException {
  FileSendNeedsUpdateException() : super(updateOtherDeviceMessage);

  @override
  String toString() => updateOtherDeviceMessage;
}

/// The peer answered `400 {"status":"stale"}`: its clock disagrees with ours.
class FileSendClockOutOfSyncException extends FileSendException {
  final String deviceName;
  FileSendClockOutOfSyncException(this.deviceName)
    : super(clockOutOfSyncMessage([deviceName]));

  @override
  String toString() => message;
}

/// How a send ended when it did not throw.
enum FileSendOutcome {
  /// The receiver confirmed it saved the file.
  delivered,

  /// Every chunk was delivered but `/v1/file/finish` timed out. The receiver
  /// may still have saved the file, so this is not a failure, and no cancel is
  /// sent.
  unconfirmed,
}

/// Sends a single file to one paired peer using the chunked protocol. Streams the file in
/// 4 MiB slices via [RandomAccessFile] — never loads the whole file. Two passes: a
/// streaming hash pass, then offer -> chunks -> finish. Reports monotonic progress and
/// honours cancellation, best-effort issuing `/v1/file/cancel` on any post-offer failure
/// except a finish timeout (see [FileSendOutcome.unconfirmed]).
class FileSender {
  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;

  /// Timeout for `/v1/file/finish`, by file size.
  final Duration Function(int fileSize) finishTimeout;

  FileSender({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
    Duration Function(int fileSize)? finishTimeout,
  }) : _client = client ?? http.Client(),
       finishTimeout = finishTimeout ?? FileTransferConstants.finishTimeout;

  Future<FileSendOutcome> sendFile({
    required File file,
    required Peer peer,
    String mimeType = 'application/octet-stream',
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final key = await pairedStore.getKey(peer.id);
    if (key == null) throw FileSendException('not paired');
    if (peer.needsUpdate) throw FileSendNeedsUpdateException();

    const chunkSize = FileTransferConstants.chunkSize;
    final fileSize = await file.length();
    final chunkCount = fileSize == 0
        ? 0
        : ((fileSize + chunkSize - 1) ~/ chunkSize);
    final filePath = file.path;
    final fileHash = await Isolate.run(
      () => ContentHasher.fileHashOfFile(File(filePath)),
    );

    final transferId = const Uuid().v4().toLowerCase();
    final fileKey = await FileTransferCrypto.deriveFileKey(key, transferId);

    final offer = FileOfferPayload(
      transferId: transferId,
      fileName: _basename(file.path),
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      createdAt: DateTime.now(),
      sourceDeviceName: identity.name,
    );

    // Offer — nothing registered on the receiver yet, so no cancel on failure.
    final offerEnvelope = await _seal(
      offer.toJson(),
      EnvelopePurpose.fileOffer,
      peer,
      key,
    );
    await _post(
      peer,
      '/v1/file/offer',
      body: utf8.encode(jsonEncode(offerEnvelope.toJson())),
      contentType: 'application/json',
    );

    try {
      if (isCancelled?.call() == true) throw FileSendCancelledException();

      if (chunkCount > 0) {
        final raf = await file.open(mode: FileMode.read);
        try {
          for (var index = 0; index < chunkCount; index++) {
            if (isCancelled?.call() == true) throw FileSendCancelledException();
            final slice = await raf.read(chunkSize);
            final sealed = await FileTransferCrypto.sealChunk(
              slice,
              fileKey,
              index,
            );
            await _post(
              peer,
              '/v1/file/chunk',
              body: sealed,
              contentType: 'application/octet-stream',
              headers: {
                FileTransferConstants.transferIdHeader: transferId,
                FileTransferConstants.chunkIndexHeader: '$index',
              },
            );
            onProgress?.call((index + 1) / chunkCount);
          }
        } finally {
          await raf.close();
        }
      }

      final finish = FileFinishPayload(transferId);
      final finishEnvelope = await _seal(
        finish.toJson(),
        EnvelopePurpose.fileFinish,
        peer,
        key,
      );
      // The receiver hashes the whole file before it answers.
      try {
        await _post(
          peer,
          '/v1/file/finish',
          body: utf8.encode(jsonEncode(finishEnvelope.toJson())),
          contentType: 'application/json',
          timeout: finishTimeout(fileSize),
        );
      } on _RequestTimeoutException {
        // The receiver may be finalizing: a cancel could delete a saved file.
        return FileSendOutcome.unconfirmed;
      }
      onProgress?.call(1.0);
      return FileSendOutcome.delivered;
    } catch (e) {
      await _bestEffortCancel(peer, transferId, key);
      rethrow;
    }
  }

  Future<void> _bestEffortCancel(
    Peer peer,
    String transferId,
    SecretKey key,
  ) async {
    try {
      final envelope = await _seal(
        FileCancelPayload(transferId).toJson(),
        EnvelopePurpose.fileCancel,
        peer,
        key,
      );
      await _post(
        peer,
        '/v1/file/cancel',
        body: utf8.encode(jsonEncode(envelope.toJson())),
        contentType: 'application/json',
      );
    } catch (_) {
      // best effort
    }
  }

  Future<ClipEnvelope> _seal(
    Map<String, dynamic> json,
    EnvelopePurpose purpose,
    Peer peer,
    SecretKey key,
  ) => CryptoEnvelopeUtils.sealJson(
    json,
    purpose: purpose,
    sourceDeviceId: identity.id,
    recipientDeviceId: peer.id,
    pairKey: key,
  );

  Future<void> _post(
    Peer peer,
    String path, {
    required List<int> body,
    required String contentType,
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: peer.host,
      port: peer.port,
      path: path,
    );
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': contentType, ...headers},
            body: body is Uint8List ? body : Uint8List.fromList(body),
          )
          .timeout(timeout ?? requestTimeout);
    } on TimeoutException {
      throw _RequestTimeoutException('$path timed out');
    }
    if (response.statusCode == 426) throw FileSendNeedsUpdateException();
    if (isStaleResponse(response.statusCode, response.body)) {
      throw FileSendClockOutOfSyncException(peer.name);
    }
    if (response.statusCode != 200) {
      throw FileSendException('$path returned ${response.statusCode}');
    }
  }

  String _basename(String path) => path.split('/').last.split('\\').last;
}
