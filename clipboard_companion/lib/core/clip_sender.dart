import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'models.dart';
import 'paired_device_store.dart';
import 'crypto_utils.dart';

class ClipSendSummary {
  final int successCount;
  final int failureCount;
  final int skippedUnpairedCount;
  final bool hasVisiblePeers;

  const ClipSendSummary({
    required this.successCount,
    required this.failureCount,
    required this.skippedUnpairedCount,
    required this.hasVisiblePeers,
  });

  bool get hasPairedTargets => successCount + failureCount > 0;
}

class ClipSender {
  final DeviceIdentity identity;
  final PairedDeviceStore pairedStore;
  final http.Client _client;
  final Duration requestTimeout;

  ClipSender({
    required this.identity,
    required this.pairedStore,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  Future<ClipSendSummary> broadcast(ClipPayload clip, List<Peer> peers) async {
    final targets = peers
        .where((p) => canonicalDeviceId(p.id) != identity.id)
        .toList();
    if (targets.isEmpty) {
      return const ClipSendSummary(
        successCount: 0,
        failureCount: 0,
        skippedUnpairedCount: 0,
        hasVisiblePeers: false,
      );
    }

    var successCount = 0;
    var failureCount = 0;
    var skippedUnpairedCount = 0;
    for (final peer in targets) {
      final key = await pairedStore.getKey(peer.id);
      if (key == null) {
        skippedUnpairedCount += 1;
        continue;
      }

      try {
        final envelope = await CryptoEnvelopeUtils.seal(clip, identity.id, key);
        final envelopeData = jsonEncode(envelope.toJson());

        final uri = Uri(
          scheme: 'http',
          host: peer.host,
          port: peer.port,
          path: '/v1/clip',
        );
        final response = await _client
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: envelopeData,
            )
            .timeout(requestTimeout);

        if (response.statusCode == 200) {
          successCount += 1;
        } else {
          failureCount += 1;
          developer.log(
            'Failed to send to ${peer.name}: ${response.statusCode}',
            name: 'ClipSender',
          );
        }
      } catch (e) {
        failureCount += 1;
        developer.log('Error sending to ${peer.name}: $e', name: 'ClipSender');
      }
    }

    return ClipSendSummary(
      successCount: successCount,
      failureCount: failureCount,
      skippedUnpairedCount: skippedUnpairedCount,
      hasVisiblePeers: true,
    );
  }
}
