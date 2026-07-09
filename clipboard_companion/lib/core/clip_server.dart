import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'models.dart';
import 'pairing_coordinator.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';

class ClipServer {
  final DeviceIdentity identity;
  final PairingCoordinator pairingCoordinator;
  final PairedDeviceStore pairedStore;
  final Function(ClipPayload) onClipReceived;

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  ClipServer({
    required this.identity,
    required this.pairingCoordinator,
    required this.pairedStore,
    required this.onClipReceived,
  });

  static String identityBody(String deviceId, String deviceName) =>
      jsonEncode({'deviceId': deviceId, 'deviceName': deviceName, 'v': 1});

  Future<void> start() async {
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

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    try {
      _server = await io.serve(handler, InternetAddress.anyIPv4, 51888);
    } on SocketException catch (e) {
      if (e.osError?.errorCode == 48 || e.osError?.errorCode == 98) {
        throw Exception('Sync port 51888 is in use');
      }
      rethrow;
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

      final connInfo = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
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

      return Response.ok(jsonEncode(respData), headers: {'Content-Type': 'application/json'});
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

      final success = await pairingCoordinator.handlePairConfirmRequest(initiatorId, proof);
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

      final payload = await CryptoEnvelopeUtils.open(envelope, key);
      onClipReceived(payload);

      return Response.ok('OK');
    } catch (e) {
      developer.log('Clip handle error: $e', name: 'ClipServer');
      return Response(400, body: e.toString());
    }
  }
}
