import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'models.dart';
import 'paired_device_store.dart';
import 'peer_browser.dart';
import 'pairing_coordinator.dart';
import 'clip_server.dart';
import 'clip_sender.dart';
import 'subnet_sweeper.dart';

List<Peer> composeSendTargets(
  List<Peer> mdnsPeers,
  List<PairedDevice> pairedDevices,
) {
  final byId = <String, Peer>{};
  for (final device in pairedDevices) {
    final host = device.host;
    if (host != null && host.isNotEmpty) {
      byId[device.id] = Peer(
        id: device.id,
        name: device.name,
        host: host,
        port: 51888,
      );
    }
  }
  for (final peer in mdnsPeers) {
    byId[peer.id] = peer;
  }
  return byId.values.toList();
}

List<Peer> composeJoinCandidates(List<Peer> mdnsPeers, List<Peer> sweptPeers) {
  final seen = <String>{};
  final result = <Peer>[];
  for (final peer in [...mdnsPeers, ...sweptPeers]) {
    if (seen.add(peer.id)) {
      result.add(peer);
    }
  }
  return result;
}

class AppState extends ChangeNotifier {
  static const MethodChannel _permissionsChannel = MethodChannel(
    'clipboard_companion/permissions',
  );

  late DeviceIdentity identity;
  late PairedDeviceStore pairedStore;
  late PeerBrowser peerBrowser;
  late PeerAdvertiser peerAdvertiser;
  late PairingCoordinator pairingCoordinator;
  late ClipServer clipServer;
  late ClipSender clipSender;
  late SharedPreferences _prefs;
  bool _coreNetworkingStarted = false;
  bool _discoveryRunning = false;

  static const _clipsKey = 'saved_clips';

  List<ClipPayload> clips = [];

  /// Invoked after an incoming clip is stored. Desktop uses this to write
  /// the clip to the system clipboard.
  void Function(ClipPayload payload)? onClipReceived;

  String? get hostCode =>
      _coreNetworkingStarted ? pairingCoordinator.hostCode : null;

  bool isReady = false;
  bool isStartingSync = false;
  bool joinInProgress = false;
  bool syncPermissionDenied = false;
  String? startupError;
  String? lastError;

  Future<void> init(SharedPreferences prefs) async {
    _prefs = prefs;
    // 1. Setup identity
    String? id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    String deviceName = Platform.isIOS
        ? 'iOS Device'
        : Platform.isWindows
        ? (Platform.environment['COMPUTERNAME'] ?? Platform.localHostname)
        : 'Android Device';
    identity = DeviceIdentity(id: id, name: deviceName);

    // 2. Setup stores
    pairedStore = PairedDeviceStore(prefs);
    _loadClips();
    notifyListeners();
  }

  Future<void> startSyncServices() async {
    if (isReady || isStartingSync) return;

    isStartingSync = true;
    syncPermissionDenied = false;
    startupError = null;
    notifyListeners();

    try {
      final hasPermission = await _requestSyncPermission();
      if (!hasPermission) {
        syncPermissionDenied = true;
        return;
      }

      await _startCoreNetworking();
      isReady = true;
    } catch (e) {
      startupError = e.toString();
    } finally {
      isStartingSync = false;
      notifyListeners();
    }
  }

  Future<void> retrySyncServices() => startSyncServices();

  Future<bool> _requestSyncPermission() async {
    if (!Platform.isAndroid) return true;

    try {
      return await _permissionsChannel.invokeMethod<bool>(
            'requestNearbyWifiPermission',
          ) ??
          false;
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> _startCoreNetworking() async {
    if (!_coreNetworkingStarted) {
      peerBrowser = PeerBrowser();
      peerAdvertiser = PeerAdvertiser();
      pairingCoordinator = PairingCoordinator(
        identity: identity,
        pairedStore: pairedStore,
      );
      clipSender = ClipSender(identity: identity, pairedStore: pairedStore);

      clipServer = ClipServer(
        identity: identity,
        pairingCoordinator: pairingCoordinator,
        pairedStore: pairedStore,
        onClipReceived: (payload) {
          clips.insert(0, payload);
          _saveClips();
          notifyListeners();
          onClipReceived?.call(payload);
        },
      );

      await clipServer.start();
      _coreNetworkingStarted = true;
    }

    if (_discoveryRunning) return;
    try {
      await peerBrowser.start(identity);
      await peerAdvertiser.start(identity, clipServer.port);
    } catch (e) {
      // mDNS is best-effort (notably flaky on Windows). Paired devices are
      // still reachable via stored hosts and the subnet sweep fallback.
      debugPrint('mDNS discovery unavailable: $e');
    }
    _discoveryRunning = true;
  }

  String startHosting() {
    final code = pairingCoordinator.startHosting();
    notifyListeners();
    return code;
  }

  void stopHosting() {
    pairingCoordinator.stopHosting();
    notifyListeners();
  }

  Future<void> joinWithCode(String code) async {
    final normalizedCode = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(normalizedCode)) {
      lastError = 'Enter a 6-digit pairing code.';
      notifyListeners();
      return;
    }

    joinInProgress = true;
    lastError = null;
    notifyListeners();

    try {
      final mdnsCandidates = peerBrowser.peers;
      if (await _tryPairing(mdnsCandidates, normalizedCode)) {
        return;
      }

      final sweptCandidates = composeJoinCandidates(
        mdnsCandidates,
        await SubnetSweeper.sweep(),
      );
      if (await _tryPairing(sweptCandidates, normalizedCode)) {
        return;
      }

      lastError =
          'No device accepted that code. Make sure the other device shows a code on the same Wi-Fi.';
    } finally {
      joinInProgress = false;
      notifyListeners();
    }
  }

  Future<bool> _tryPairing(List<Peer> candidates, String code) async {
    for (final peer in candidates) {
      try {
        await pairingCoordinator.startPairing(peer, code);
        lastError = null;
        notifyListeners();
        return true;
      } catch (_) {
        // Wrong code, not in hosting mode, or unreachable: try the next candidate.
      }
    }
    return false;
  }

  Future<void> pauseSyncServices() async {
    if (!_coreNetworkingStarted || !_discoveryRunning) return;
    await peerBrowser.stop();
    await peerAdvertiser.stop();
    _discoveryRunning = false;
    isReady = false;
    notifyListeners();
  }

  Future<void> resumeSyncServices() => startSyncServices();

  Future<ClipSendSummary> sendClip(ClipPayload clip) async {
    // Add to local UI
    clips.insert(0, clip);
    _saveClips();
    notifyListeners();

    // Broadcast
    final targets = composeSendTargets(peerBrowser.peers, pairedStore.devices);
    return clipSender.broadcast(clip, targets);
  }

  Future<void> deleteClip(String id) async {
    final initialCount = clips.length;
    clips.removeWhere((clip) => clip.id == id);
    if (clips.length == initialCount) return;

    await _saveClips();
    notifyListeners();
  }

  Future<void> clearClips() async {
    if (clips.isEmpty) return;

    clips.clear();
    await _saveClips();
    notifyListeners();
  }

  void _loadClips() {
    final clipsJson = _prefs.getString(_clipsKey);
    if (clipsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(clipsJson);
        final loadedClips = decoded
            .map((e) => ClipPayload.fromJson(e as Map<String, dynamic>))
            .toList();

        final now = DateTime.now();
        clips = loadedClips.where((clip) {
          return now.difference(clip.createdAt).inDays < 7;
        }).toList();

        if (clips.length != loadedClips.length) {
          _saveClips();
        }
      } catch (e) {
        debugPrint('Error loading clips: $e');
        clips = [];
      }
    }
  }

  Future<void> _saveClips() async {
    final now = DateTime.now();
    clips.removeWhere((clip) => now.difference(clip.createdAt).inDays >= 7);
    final clipsJson = jsonEncode(clips.map((e) => e.toJson()).toList());
    await _prefs.setString(_clipsKey, clipsJson);
  }

  @override
  void dispose() {
    if (_coreNetworkingStarted) {
      unawaited(peerBrowser.stop());
      unawaited(peerAdvertiser.stop());
      unawaited(clipServer.stop());
    }
    super.dispose();
  }
}
