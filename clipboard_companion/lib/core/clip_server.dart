import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'models.dart';
import 'pairing_coordinator.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';
import 'file_receiver.dart';
import 'file_transfer_models.dart';
import 'image_validation.dart';
import 'liveness_ping.dart';
import 'replay_guard.dart';

class ClipServerStartException implements Exception {
  final String message;
  const ClipServerStartException(this.message);

  @override
  String toString() => message;
}

/// Largest request body any route accepts (mirrors the Mac and Windows HTTP codecs).
const int maxRequestBodySize = 20 * 1024 * 1024;

/// Thrown by [readBodyCapped] when a request body is larger than allowed.
class BodyTooLargeException implements Exception {
  const BodyTooLargeException();

  @override
  String toString() => 'Request body too large';
}

/// Reads a request body without ever buffering more than [max] bytes (shelf has no cap of
/// its own). Rejects up front when `Content-Length` already exceeds [max], and stops reading
/// as soon as the running total does.
Future<Uint8List> readBodyCapped(
  Request request, {
  int max = maxRequestBodySize,
}) async {
  final declared = request.contentLength;
  if (declared != null && declared > max) {
    throw const BodyTooLargeException();
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (builder.length + chunk.length > max) {
      throw const BodyTooLargeException();
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<dynamic> _readJsonCapped(Request request) async =>
    jsonDecode(utf8.decode(await readBodyCapped(request)));

Response _payloadTooLarge() => Response(413, body: 'Payload Too Large');

/// 426 for an envelope whose `v` is not [wireProtocolVersion].
Response _upgradeRequired() => Response(
  426,
  body: jsonEncode(upgradeRequiredBody),
  headers: {'Content-Type': 'application/json'},
);

const upgradeRequiredBody = {
  'status': 'upgradeRequired',
  'minVersion': wireProtocolVersion,
};

class ClipServer {
  final DeviceIdentity identity;
  final PairingCoordinator pairingCoordinator;
  final PairedDeviceStore pairedStore;
  final Function(ClipPayload) onClipReceived;
  final FileReceiver? fileReceiver;

  /// Shared with [fileReceiver] in production (one guard per process).
  final ReplayGuard replayGuard;

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  ClipServer({
    required this.identity,
    required this.pairingCoordinator,
    required this.pairedStore,
    required this.onClipReceived,
    this.fileReceiver,
    ReplayGuard? replayGuard,
  }) : replayGuard = replayGuard ?? ReplayGuard();

  static String identityBody(String deviceId, String deviceName) => jsonEncode({
    'deviceId': deviceId,
    'deviceName': deviceName,
    'v': wireProtocolVersion,
  });

  static String startErrorMessage(SocketException error) {
    final lower = error.message.toLowerCase();
    final addressInUse =
        error.osError?.errorCode == 48 ||
        error.osError?.errorCode == 98 ||
        error.osError?.errorCode == 10048 ||
        lower.contains('shared flag') ||
        lower.contains('address already in use');
    return addressInUse
        ? 'Sync port 51888 is already in use.'
        : 'Could not start sync networking: ${error.message}';
  }

  /// Builds the request handler (routes + pipeline). Exposed for testing without binding
  /// a socket.
  Handler buildHandler() {
    final router = Router();

    router.get('/v1/id', (Request request) {
      return Response.ok(
        identityBody(identity.id, identity.name),
        headers: {'Content-Type': 'application/json'},
      );
    });
    router.post('/v1/pair/start', _handlePairStart);
    router.post('/v1/pair/reveal', _handlePairReveal);
    // The target may hold this up to 60 s for its user; shelf has no request
    // deadline, and clients use a 75 s timeout for it.
    router.post('/v1/pair/confirm', _handlePairConfirm);
    router.post(LivenessPing.path, _handlePing);
    router.post('/v1/clip', _handleClip);
    router.post('/v1/file/offer', _handleFileOffer);
    router.post('/v1/file/chunk', _handleFileChunk);
    router.post('/v1/file/finish', _handleFileFinish);
    router.post('/v1/file/cancel', _handleFileCancel);

    return const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);
  }

  Future<void> start() async {
    final handler = buildHandler();

    try {
      _server = await io.serve(handler, InternetAddress.anyIPv4, 51888);
    } on SocketException catch (e) {
      throw ClipServerStartException(startErrorMessage(e));
    }
    developer.log('Listening on port ${_server!.port}', name: 'ClipServer');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _handlePairStart(Request request) async {
    try {
      final body = await _readJsonCapped(request);

      final initiatorId = body['deviceId'] as String;
      final initiatorName = body['deviceName'] as String;
      final commitmentBase64 = body['commitment'] as String;

      final connInfo =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final remoteHost = connInfo?.remoteAddress.address ?? '';
      final targetPubKeyBase64 = await pairingCoordinator.handlePairStart(
        initiatorId,
        initiatorName,
        commitmentBase64,
        remoteHost,
      );

      final respData = {
        'deviceId': identity.id,
        'deviceName': identity.name,
        'ephemeralPublicKey': targetPubKeyBase64,
      };

      return Response.ok(
        jsonEncode(respData),
        headers: {'Content-Type': 'application/json'},
      );
    } on PairingRejectedException catch (e) {
      developer.log('Pair start rejected: ${e.reason}', name: 'ClipServer');
      return Response.forbidden('Rejected');
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      developer.log('Pair start error: $e', name: 'ClipServer');
      return Response.internalServerError(body: 'Internal error');
    }
  }

  Future<Response> _handlePairReveal(Request request) async {
    try {
      final body = await _readJsonCapped(request);
      final outcome = await pairingCoordinator.handlePairReveal(
        body['deviceId'] as String,
        body['ephemeralPublicKey'] as String,
        body['salt'] as String,
      );
      switch (outcome) {
        case PairRevealOutcome.ok:
          return Response.ok(
            jsonEncode({'status': 'ok'}),
            headers: {'Content-Type': 'application/json'},
          );
        case PairRevealOutcome.rejected:
          return Response(401, body: 'Unauthorized');
        case PairRevealOutcome.invalid:
          return Response(400, body: 'Bad request');
      }
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      developer.log('Pair reveal error: ${e.runtimeType}', name: 'ClipServer');
      return Response(400, body: 'Bad request');
    }
  }

  Future<Response> _handlePairConfirm(Request request) async {
    try {
      final body = await _readJsonCapped(request);

      final initiatorId = body['deviceId'] as String;
      final proof = body['proof'] as String;

      final outcome = await pairingCoordinator.handlePairConfirmRequest(
        initiatorId,
        proof,
      );
      switch (outcome) {
        case PairConfirmOutcome.paired:
          return Response.ok(
            jsonEncode({'status': 'ok'}),
            headers: {'Content-Type': 'application/json'},
          );
        case PairConfirmOutcome.timedOut:
          return Response(
            408,
            body: jsonEncode({'status': 'timeout'}),
            headers: {'Content-Type': 'application/json'},
          );
        case PairConfirmOutcome.alreadyPaired:
          return Response(
            409,
            body: jsonEncode({'status': 'alreadyPaired'}),
            headers: {'Content-Type': 'application/json'},
          );
        case PairConfirmOutcome.rejected:
          return Response(401, body: 'Invalid proof');
      }
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      developer.log('Pair confirm error: $e', name: 'ClipServer');
      return Response(400, body: 'Bad request');
    }
  }

  Future<Response> _handlePing(Request request) async {
    try {
      final envelope = ClipEnvelope.fromJson(await _readJsonCapped(request));
      final (status, body) = await LivenessPing.respond(
        envelope: envelope,
        localDeviceId: identity.id,
        getKey: pairedStore.getKey,
        replayGuard: replayGuard,
      );
      return Response(
        status,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (_) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }

  Future<Response> _handleClip(Request request) async {
    try {
      final body = await _readJsonCapped(request);

      final envelope = ClipEnvelope.fromJson(body);
      if (envelope.v != wireProtocolVersion) return _upgradeRequired();

      final key = await pairedStore.getKey(envelope.sourceDeviceId);
      if (key == null) {
        return Response(401, body: 'Not paired');
      }
      if (!pairedStore.isConnected(envelope.sourceDeviceId)) {
        // Pausing is local; remote devices may still try to send and receive 401.
        return Response(401, body: 'Paused');
      }

      final json = await CryptoEnvelopeUtils.openJson(
        envelope,
        purpose: EnvelopePurpose.clip,
        recipientDeviceId: identity.id,
        pairKey: key,
      );
      // Only after a successful open, and before any side effect.
      final rejection = replayRejection(
        replayGuard.check(
          sourceDeviceId: envelope.sourceDeviceId,
          nonce: envelope.nonce,
          sentAt: sentAtOf(json),
        ),
      );
      if (rejection != null) {
        final (status, body) = rejection;
        return Response(
          status,
          body: jsonEncode(body),
          headers: {'Content-Type': 'application/json'},
        );
      }
      final payload = acceptReceivedClip(ClipPayload.fromJson(json));
      if (payload == null) {
        return Response(400, body: 'Invalid image payload');
      }
      onClipReceived(payload);

      return Response.ok('OK');
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      developer.log('Clip handle error: $e', name: 'ClipServer');
      return Response(400, body: 'Bad request');
    }
  }

  // MARK: - File transfer

  Response _fileResponse(FileTransferResponse result) => Response(
    result.statusCode,
    body: jsonEncode(result.body),
    headers: {'Content-Type': 'application/json'},
  );

  Future<Response> _handleFileOffer(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    try {
      final envelope = ClipEnvelope.fromJson(await _readJsonCapped(request));
      return _fileResponse(await receiver.handleOffer(envelope));
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }

  Future<Response> _handleFileChunk(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    // Codecs lowercase header keys.
    final transferId =
        request.headers[FileTransferConstants.transferIdHeader.toLowerCase()] ??
        '';
    final index =
        int.tryParse(
          request.headers[FileTransferConstants.chunkIndexHeader
                  .toLowerCase()] ??
              '',
        ) ??
        -1;
    // shelf has no body cap; enforce one manually (chunk plaintext + tag + slack).
    final Uint8List body;
    try {
      body = await readBodyCapped(
        request,
        max: FileTransferConstants.chunkSize + 4096,
      );
    } on BodyTooLargeException {
      return _fileResponse(FileTransferResponse(400, {'status': 'tooLarge'}));
    }
    return _fileResponse(await receiver.handleChunk(transferId, index, body));
  }

  Future<Response> _handleFileFinish(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    try {
      final envelope = ClipEnvelope.fromJson(await _readJsonCapped(request));
      return _fileResponse(await receiver.handleFinish(envelope));
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }

  Future<Response> _handleFileCancel(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    try {
      final envelope = ClipEnvelope.fromJson(await _readJsonCapped(request));
      return _fileResponse(await receiver.handleCancel(envelope));
    } on BodyTooLargeException {
      return _payloadTooLarge();
    } catch (e) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }
}
