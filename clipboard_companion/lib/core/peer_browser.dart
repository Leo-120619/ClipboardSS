import 'dart:async';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'models.dart';

class PeerBrowser {
  final String _type = '_clipboardss._tcp';
  BonsoirDiscovery? _browser;
  StreamSubscription? _subscription;

  final StreamController<List<Peer>> _peersController = StreamController<List<Peer>>.broadcast();
  Stream<List<Peer>> get peersStream => _peersController.stream;

  final Map<String, Peer> _peers = {};
  List<Peer> get peers => _peers.values.toList();

  Future<void> start(DeviceIdentity identity) async {
    await stop();

    final selfId = canonicalDeviceId(identity.id);

    _browser = BonsoirDiscovery(type: _type);
    await _browser!.initialize();

    _subscription = _browser!.eventStream?.listen((event) {
      if (event is BonsoirDiscoveryServiceResolvedEvent ||
          event is BonsoirDiscoveryServiceFoundEvent) {
        if (event.service != null) {
          final resolved = event.service!;
          final host = bestHostAddress(resolved.hostAddresses);
          if (host != null) {
            final peer = peerFromAttributes(
              serviceName: resolved.name,
              attrs: resolved.attributes,
              host: host,
              port: resolved.port,
              selfId: selfId,
            );
            if (peer == null) {
              return;
            }

            _peers[resolved.name] = peer;
            _peersController.add(_peers.values.toList());
          } else {
            _browser!.serviceResolver.resolveService(resolved);
          }
        }
      } else if (event is BonsoirDiscoveryServiceLostEvent) {
        _peers.remove(event.service.name);
        _peersController.add(_peers.values.toList());
      }
    });

    await _browser!.start();
  }

  static String? _getValueCaseInsensitive(Map<String, String>? map, String key) {
    if (map == null) return null;
    if (map.containsKey(key)) return map[key];
    final lowerKey = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lowerKey) {
        return entry.value;
      }
    }
    return null;
  }

  static Peer? peerFromAttributes({
    required String serviceName,
    required Map<String, String>? attrs,
    required String host,
    required int port,
    required String selfId,
  }) {
    final id = canonicalDeviceId(_getValueCaseInsensitive(attrs, 'deviceId') ?? serviceName);
    if (id == selfId) {
      return null;
    }
    final name = _getValueCaseInsensitive(attrs, 'deviceName') ?? serviceName;

    return Peer(
      id: id,
      name: name,
      host: host,
      port: port,
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _browser?.stop();
    _subscription = null;
    _browser = null;
    _peers.clear();
    _peersController.add([]);
  }

  static String? bestHostAddress(List<String> hosts) {
    for (final host in hosts) {
      final address = InternetAddress.tryParse(host);
      if (address?.type == InternetAddressType.IPv4) return host;
    }

    for (final host in hosts) {
      if (InternetAddress.tryParse(host) != null) return host;
    }

    return hosts.firstOrNull;
  }
}

class PeerAdvertiser {
  final String _type = '_clipboardss._tcp';
  BonsoirBroadcast? _broadcast;

  Future<void> start(DeviceIdentity identity, int port) async {
    await stop();

    final service = BonsoirService(
      name: identity.id, // Using device ID as service name, similar to Mac
      type: _type,
      port: port,
      attributes: {
        'deviceId': identity.id,
        'deviceName': identity.name,
        'v': '1',
      },
    );

    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
  }
}
