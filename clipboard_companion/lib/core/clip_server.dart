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

class ClipServerStartException implements Exception {
  final String message;
  const ClipServerStartException(this.message);

  @override
  String toString() => message;
}

class ClipServer {
  final DeviceIdentity identity;
  final PairingCoordinator pairingCoordinator;
  final PairedDeviceStore pairedStore;
  final Function(ClipPayload) onClipReceived;
  final FileReceiver? fileReceiver;

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  ClipServer({
    required this.identity,
    required this.pairingCoordinator,
    required this.pairedStore,
    required this.onClipReceived,
    this.fileReceiver,
  });

  static String identityBody(String deviceId, String deviceName) =>
      jsonEncode({'deviceId': deviceId, 'deviceName': deviceName, 'v': 1});

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
    router.post('/v1/pair/confirm', _handlePairConfirm);
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
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr);

      final initiatorId = body['deviceId'] as String;
      final initiatorName = body['deviceName'] as String;
      final initiatorPubKeyBase64 = body['ephemeralPublicKey'] as String;

      final connInfo =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final remoteHost = connInfo?.remoteAddress.address ?? '';
      final targetPubKeyBase64 = await pairingCoordinator.handlePairStart(
        initiatorId,
        initiatorName,
        initiatorPubKeyBase64,
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
    } catch (e) {
      developer.log('Pair start error: $e', name: 'ClipServer');
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _handlePairConfirm(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr);

      final initiatorId = body['deviceId'] as String;
      final proof = body['proof'] as String;

      final success = await pairingCoordinator.handlePairConfirmRequest(
        initiatorId,
        proof,
      );
      if (success) {
        return Response.ok('OK');
      } else {
        return Response(401, body: 'Invalid proof');
      }
    } catch (e) {
      developer.log('Pair confirm error: $e', name: 'ClipServer');
      return Response(400, body: e.toString());
    }
  }

  Future<Response> _handleClip(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr);

      final envelope = ClipEnvelope.fromJson(body);

      final key = await pairedStore.getKey(envelope.sourceDeviceId);
      if (key == null) {
        return Response(401, body: 'Not paired');
      }
      if (!pairedStore.isConnected(envelope.sourceDeviceId)) {
        // Pausing is local; remote devices may still try to send and receive 401.
        return Response(401, body: 'Paused');
      }

      final payload = await CryptoEnvelopeUtils.open(envelope, key);
      onClipReceived(payload);

      return Response.ok('OK');
    } catch (e) {
      developer.log('Clip handle error: $e', name: 'ClipServer');
      return Response(400, body: e.toString());
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
      final envelope = ClipEnvelope.fromJson(
        jsonDecode(await request.readAsString()),
      );
      return _fileResponse(await receiver.handleOffer(envelope));
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
    final body = await _readRawBody(
      request,
      FileTransferConstants.chunkSize + 4096,
    );
    if (body == null) {
      return _fileResponse(FileTransferResponse(400, {'status': 'tooLarge'}));
    }
    return _fileResponse(await receiver.handleChunk(transferId, index, body));
  }

  Future<Response> _handleFileFinish(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    try {
      final envelope = ClipEnvelope.fromJson(
        jsonDecode(await request.readAsString()),
      );
      return _fileResponse(await receiver.handleFinish(envelope));
    } catch (e) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }

  Future<Response> _handleFileCancel(Request request) async {
    final receiver = fileReceiver;
    if (receiver == null) return Response.notFound('Not Found');
    try {
      final envelope = ClipEnvelope.fromJson(
        jsonDecode(await request.readAsString()),
      );
      return _fileResponse(await receiver.handleCancel(envelope));
    } catch (e) {
      return Response(400, body: jsonEncode({'status': 'error'}));
    }
  }

  /// Reads the raw request body, returning null if it exceeds [maxBytes].
  Future<List<int>?> _readRawBody(Request request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    return builder.takeBytes();
  }
}
