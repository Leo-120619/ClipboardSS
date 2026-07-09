import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class SubnetSweeper {
  static const int fixedPort = 51888;

  static List<String> hostAddresses(String ownIPv4, int prefixLen) {
    if (prefixLen != 24) return [];

    final parts = ownIPv4.split('.');
    if (parts.length != 4) return [];
    final octets = <int>[];
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return [];
      octets.add(octet);
    }

    final base = '${octets[0]}.${octets[1]}.${octets[2]}';
    final result = <String>[];
    for (var last = 1; last <= 254; last += 1) {
      final addr = '$base.$last';
      if (addr == ownIPv4) continue;
      result.add(addr);
    }
    return result;
  }

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

      return Peer(
        id: deviceId,
        name: deviceName is String && deviceName.isNotEmpty ? deviceName : host,
        host: host,
        port: fixedPort,
      );
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
  }) async {
    final ip = await _ownIPv4();
    if (ip == null) return [];

    final hosts = hostAddresses(ip, 24);
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

  static Future<String?> _ownIPv4() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final ni in interfaces) {
      for (final address in ni.addresses) {
        final value = address.address;
        if (address.isLoopback) continue;
        if (_isPrivateIPv4(value)) return value;
      }
    }
    return null;
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
