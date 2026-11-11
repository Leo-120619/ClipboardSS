import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'sweep_interfaces.dart';

export 'sweep_interfaces.dart' show SweepInterface;

class SubnetSweeper {
  static const int fixedPort = 51888;

  /// Masks wider than this are capped (matches the Mac): at most 1,021 hosts.
  static const int widestPrefix = 22;

  /// Hosts in the block [prefixLen] carves around [ownIPv4] (capped at
  /// [widestPrefix]), without the network and broadcast addresses or self.
  static List<String> hostAddresses(String ownIPv4, int prefixLen) {
    final own = _parseIPv4(ownIPv4);
    if (own == null || prefixLen < 0 || prefixLen > 30) return [];

    final prefix = prefixLen < widestPrefix ? widestPrefix : prefixLen;
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final network = own & mask;
    final broadcast = network | (~mask & 0xFFFFFFFF);
    final result = <String>[];
    for (var host = network + 1; host < broadcast; host += 1) {
      if (host == own) continue;
      result.add(_formatIPv4(host));
    }
    return result;
  }

  /// The interface to sweep: a private-LAN one, preferring the one holding
  /// the default route, then Wi-Fi/Ethernet over cellular, then list order.
  static SweepInterface? pickInterface(List<SweepInterface> candidates) {
    final usable = candidates
        .where((c) => _isPrivateIPv4(c.address))
        .toList(growable: false);
    if (usable.isEmpty) return null;
    int rank(SweepInterface c) =>
        (c.isDefaultRoute ? 0 : 2) + (_looksLikeLan(c.name) ? 0 : 1);
    var best = usable.first;
    for (final c in usable.skip(1)) {
      if (rank(c) < rank(best)) best = c;
    }
    return best;
  }

  static bool _looksLikeLan(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('en') ||
        lower.startsWith('eth') ||
        lower.startsWith('wlan') ||
        lower.startsWith('wl');
  }

  static int? _parseIPv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      value = (value << 8) | octet;
    }
    return value;
  }

  static String _formatIPv4(int value) =>
      '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
      '${(value >> 8) & 0xFF}.${value & 0xFF}';

  static Future<Peer?> probeHost(
    String host, {
    http.Client? client,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final effectiveClient = client ?? http.Client();
    final shouldClose = client == null;
    try {
      final response = await effectiveClient
          .get(Uri(scheme: 'http', host: host, port: fixedPort, path: '/v1/id'))
          .timeout(timeout);
      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final deviceId = body['deviceId'];
      if (deviceId is! String || deviceId.isEmpty) return null;
      final deviceName = body['deviceName'];
      final version = body['v'];

      return Peer(
        id: deviceId,
        name: deviceName is String && deviceName.isNotEmpty ? deviceName : host,
        host: host,
        port: fixedPort,
        protocolVersion: version is int ? version : 1,
      );
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) effectiveClient.close();
    }
  }

  /// POSTs a ping envelope [body] to `/v1/ping` on [host]. Returns
  /// `(statusCode, body)`, or null when the host did not answer in time.
  static Future<(int, String)?> postPing(
    String host,
    String body, {
    http.Client? client,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final effectiveClient = client ?? http.Client();
    final shouldClose = client == null;
    try {
      final response = await effectiveClient
          .post(
            Uri(scheme: 'http', host: host, port: fixedPort, path: '/v1/ping'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
      return (response.statusCode, response.body);
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) effectiveClient.close();
    }
  }

  static Future<List<Peer>> sweep({
    int timeoutMs = 500,
    int concurrency = 32,
    http.Client? client,
    Future<List<SweepInterface>> Function()? interfaces,
  }) async {
    final List<SweepInterface> candidates;
    try {
      candidates = await (interfaces ?? listSweepInterfaces)();
    } catch (_) {
      return [];
    }
    final target = pickInterface(candidates);
    if (target == null) return [];

    final hosts = hostAddresses(target.address, target.prefixLength);
    if (hosts.isEmpty) return [];

    final effectiveClient = client ?? http.Client();
    final shouldClose = client == null;
    final found = <Peer>[];
    var nextIndex = 0;
    final workerCount = concurrency.clamp(1, hosts.length);

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= hosts.length) return;
        nextIndex += 1;

        final peer = await probeHost(
          hosts[index],
          client: effectiveClient,
          timeout: Duration(milliseconds: timeoutMs),
        );
        if (peer != null) found.add(peer);
      }
    }

    try {
      await Future.wait(List.generate(workerCount, (_) => worker()));
      return found;
    } finally {
      if (shouldClose) effectiveClient.close();
    }
  }

  static bool _isPrivateIPv4(String address) {
    if (address.startsWith('10.')) return true;
    if (address.startsWith('192.168.')) return true;
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]);
    return parts[0] == '172' && second != null && second >= 16 && second <= 31;
  }
}
