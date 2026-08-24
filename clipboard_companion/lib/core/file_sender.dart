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

/// Sends a single file to one paired peer using the chunked protocol. Streams the file in
/// 4 MiB slices via [RandomAccessFile] — never loads the whole file. Two passes: a
/// streaming hash pass, then offer -> chunks -> finish. Reports monotonic progress and
/// honours cancellation, best-effort issuing `/v1/file/cancel` on any post-offer failure.
class FileSender {
  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;

  FileSender({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  Future<void> sendFile({
    required File file,
    required Peer peer,
    String mimeType = 'application/octet-stream',
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final key = await pairedStore.getKey(peer.id);
    if (key == null) throw FileSendException('not paired');

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
    final offerEnvelope = await CryptoEnvelopeUtils.sealJson(
      offer.toJson(),
      identity.id,
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
      final finishEnvelope = await CryptoEnvelopeUtils.sealJson(
        finish.toJson(),
        identity.id,
        key,
      );
      await _post(
        peer,
        '/v1/file/finish',
        body: utf8.encode(jsonEncode(finishEnvelope.toJson())),
        contentType: 'application/json',
      );
      onProgress?.call(1.0);
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
      final envelope = await CryptoEnvelopeUtils.sealJson(
        FileCancelPayload(transferId).toJson(),
        identity.id,
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

  Future<void> _post(
    Peer peer,
    String path, {
    required List<int> body,
    required String contentType,
    Map<String, String> headers = const {},
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
          .timeout(requestTimeout);
    } on TimeoutException {
      throw FileSendException('$path timed out');
    }
    if (response.statusCode != 200) {
      throw FileSendException('$path returned ${response.statusCode}');
    }
  }

  String _basename(String path) => path.split('/').last.split('\\').last;
}
