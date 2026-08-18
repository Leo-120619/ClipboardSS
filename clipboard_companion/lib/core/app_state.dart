import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
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
import 'file_receiver.dart';
import 'file_sender.dart';
import 'file_transfer_ui.dart';
import 'incoming_share.dart';
import 'android_downloads.dart';
import 'subnet_sweeper.dart';
import 'received_file_notifications.dart';

class AsyncOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((_) {});
    return result;
  }
}

bool isDeviceConnectionActive({required bool enabled, required bool online}) =>
    enabled && online;

Peer? matchingReconnectPeer({
  required String deviceId,
  required List<Peer> mdnsPeers,
  required List<Peer> sweptPeers,
}) {
  final canonical = canonicalDeviceId(deviceId);
  for (final peer in [...mdnsPeers, ...sweptPeers]) {
    if (canonicalDeviceId(peer.id) == canonical) return peer;
  }
  return null;
}

Peer? resolveVerifiedPeer({
  required PairedDevice device,
  required bool online,
  required List<Peer> mdnsPeers,
}) {
  if (!isDeviceConnectionActive(enabled: device.connected, online: online)) {
    return null;
  }
  final canonical = canonicalDeviceId(device.id);
  for (final peer in mdnsPeers) {
    if (canonicalDeviceId(peer.id) == canonical) return peer;
  }
  final host = device.host;
  if (host == null || host.isEmpty) return null;
  return Peer(
    id: canonical,
    name: device.name,
    host: host,
    port: SubnetSweeper.fixedPort,
  );
}

List<Peer> composeSendTargets(
  List<Peer> mdnsPeers,
  List<PairedDevice> pairedDevices,
) {
  final byId = <String, Peer>{};
  for (final device in pairedDevices.where((device) => device.connected)) {
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
  final pairedById = {for (final device in pairedDevices) device.id: device};
  for (final peer in mdnsPeers) {
    final paired = pairedById[peer.id];
    if (paired == null || paired.connected) byId[peer.id] = peer;
  }
  return byId.values.toList();
}

/// Resolves whether each paired device is reachable right now. mDNS and the
/// stored address provide candidates, but [probe] must confirm that a candidate
/// answers with the expected device id. Independent of [PairedDevice.connected],
/// which is a local pause switch rather than a statement about reachability.
Future<Map<String, bool>> computeDeviceLiveness({
  required List<PairedDevice> devices,
  required List<Peer> mdnsPeers,
  required Future<Peer?> Function(String host) probe,
}) async {
  final online = <String, bool>{};

  await Future.wait(
    devices.map((device) async {
      final id = canonicalDeviceId(device.id);
      final hosts = mdnsPeers
          .where((peer) => canonicalDeviceId(peer.id) == id)
          .map((peer) => peer.host)
          .toList();
      final host = device.host;
      if (host != null && host.isNotEmpty && !hosts.contains(host)) {
        hosts.add(host);
      }
      if (hosts.isEmpty) {
        online[id] = false;
        return;
      }
      for (final candidate in hosts) {
        final peer = await probe(candidate);
        if (peer != null && canonicalDeviceId(peer.id) == id) {
          online[id] = true;
          return;
        }
      }
      online[id] = false;
    }),
  );

  return online;
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
  static const MethodChannel _shareChannel = MethodChannel(
    'clipboard_companion/incoming_share',
  );
  final AndroidDownloads _androidDownloads;
  late final ReceivedFileNotifications _receivedFileNotifications;
  final Set<String> _notifiedReceiveIds = <String>{};

  AppState({
    AndroidDownloads? androidDownloads,
    ReceivedFileNotifications? receivedFileNotifications,
  }) : _androidDownloads = androidDownloads ?? AndroidDownloads() {
    _receivedFileNotifications =
        receivedFileNotifications ??
        LocalReceivedFileNotifications(openMobileDownloads: openDownloads);
  }

  late DeviceIdentity identity;
  late PairedDeviceStore pairedStore;
  late PeerBrowser peerBrowser;
  late PeerAdvertiser peerAdvertiser;
  late PairingCoordinator pairingCoordinator;
  late ClipServer clipServer;
  late ClipSender clipSender;
  late FileSender fileSender;
  late FileReceiver fileReceiver;
  late SharedPreferences _prefs;
  bool _coreNetworkingStarted = false;
  bool _discoveryRunning = false;

  StreamSubscription<FileTransferReceiveEvent>? _transferSub;
  Timer? _transferGcTimer;
  Timer? _livenessTimer;
  http.Client? _livenessClient;
  final AsyncOperationQueue _networkTransitions = AsyncOperationQueue();

  /// Live reachability per paired device id. In-memory only: it is rebuilt from
  /// scratch on every refresh, so unpaired devices drop out on their own.
  final Map<String, bool> deviceOnline = {};
  final Map<String, TransferCancelToken> _sendTokens = {};
  final Set<String> _consumedShareBatchIds = {};
  IncomingShareBatch? pendingShareBatch;
  bool isSendingBatch = false;

  /// In-flight and finished transfers (both directions), newest first.
  final List<FileTransferUiState> transfers = [];

  static const _livenessInterval = Duration(seconds: 5);
  static const _clipsKey = 'saved_clips';
  static const _maxPersistedClipBytes = 4 * 1024 * 1024;
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
    await _receivedFileNotifications.initialize();
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
    if (Platform.isAndroid || Platform.isIOS) {
      _shareChannel.setMethodCallHandler(_handleShareMethod);
      final initial = await _shareChannel.invokeMapMethod<Object?, Object?>(
        'getInitialShare',
      );
      if (initial != null) _stageIncomingShare(initial);
    }
    notifyListeners();
  }

  Future<Object?> _handleShareMethod(MethodCall call) async {
    if (call.method == 'incomingShare' && call.arguments is Map) {
      _stageIncomingShare(Map<Object?, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  void _stageIncomingShare(Map<Object?, Object?> value) {
    final batch = IncomingShareBatch.fromMap(value);
    if (batch.attachments.isEmpty ||
        _consumedShareBatchIds.contains(batch.id) ||
        pendingShareBatch?.id == batch.id) {
      return;
    }
    pendingShareBatch = batch;
    notifyListeners();
  }

  Future<void> dismissPendingShare() async {
    final batch = pendingShareBatch;
    if (batch == null) return;
    pendingShareBatch = null;
    _consumedShareBatchIds.add(batch.id);
    notifyListeners();
    await _shareChannel.invokeMethod<void>('completeShare', {'id': batch.id});
  }

  Future<void> sendPendingShareTo(String deviceId) async {
    final batch = pendingShareBatch;
    if (batch == null || isSendingBatch) return;
    isSendingBatch = true;
    notifyListeners();
    try {
      var allSucceeded = true;
      for (final attachment in batch.attachments) {
        if (!attachment.file.existsSync()) {
          allSucceeded = false;
          continue;
        }
        allSucceeded =
            await sendFileTo(attachment.file, deviceId) && allSucceeded;
      }
      if (allSucceeded) await dismissPendingShare();
    } finally {
      isSendingBatch = false;
      notifyListeners();
    }
  }

  Future<void> sendFilesTo(List<File> files, String deviceId) async {
    if (isSendingBatch || files.isEmpty) return;
    isSendingBatch = true;
    notifyListeners();
    try {
      for (final file in files) {
        await sendFileTo(file, deviceId);
      }
    } finally {
      isSendingBatch = false;
      notifyListeners();
    }
  }

  Future<void> startSyncServices() =>
      _enqueueNetworkTransition(_startSyncServices);

  Future<void> _startSyncServices() async {
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

  Future<void> _enqueueNetworkTransition(Future<void> Function() operation) =>
      _networkTransitions.run(operation);

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
      final nextPeerBrowser = PeerBrowser();
      final nextPeerAdvertiser = PeerAdvertiser();
      final nextPairingCoordinator = PairingCoordinator(
        identity: identity,
        pairedStore: pairedStore,
      );
      final nextClipSender = ClipSender(
        identity: identity,
        pairedStore: pairedStore,
      );
      final nextFileSender = FileSender(
        identity: identity,
        pairedStore: pairedStore,
      );

      final tempDir = await getTemporaryDirectory();
      final transfersDir = Directory('${tempDir.path}/Transfers');
      final destinationDir = await _resolveDestinationDir();
      final nextFileReceiver = FileReceiver(
        pairedStore: pairedStore,
        transfersDirectory: transfersDir,
        destinationProvider: () => destinationDir,
      );

      final nextClipServer = ClipServer(
        identity: identity,
        pairingCoordinator: nextPairingCoordinator,
        pairedStore: pairedStore,
        onClipReceived: (payload) {
          clips.insert(0, payload);
          _saveClips();
          notifyListeners();
          onClipReceived?.call(payload);
        },
        fileReceiver: nextFileReceiver,
      );

      try {
        await nextClipServer.start();
      } catch (_) {
        await nextFileReceiver.dispose();
        rethrow;
      }

      peerBrowser = nextPeerBrowser;
      peerAdvertiser = nextPeerAdvertiser;
      pairingCoordinator = nextPairingCoordinator;
      clipSender = nextClipSender;
      fileSender = nextFileSender;
      fileReceiver = nextFileReceiver;
      clipServer = nextClipServer;
      _transferSub = fileReceiver.events.listen(handleReceiveEvent);
      _transferGcTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => fileReceiver.garbageCollect(),
      );
      _coreNetworkingStarted = true;
    }

    _startLivenessTimer();

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
        unawaited(refreshDeviceLiveness());
        return true;
      } catch (_) {
        // Wrong code, not in hosting mode, or unreachable: try the next candidate.
      }
    }
    return false;
  }

  Future<void> pauseSyncServices() =>
      _enqueueNetworkTransition(_pauseSyncServices);

  Future<void> _pauseSyncServices() async {
    if (!_coreNetworkingStarted || !_discoveryRunning) return;
    _stopLivenessTimer();
    await peerBrowser.stop();
    await peerAdvertiser.stop();
    _discoveryRunning = false;
    isReady = false;
    notifyListeners();
  }

  Future<void> setDeviceConnected(String id, bool connected) async {
    if (connected) deviceOnline.remove(canonicalDeviceId(id));
    await pairedStore.setConnected(id, connected);
    if (connected) {
      await reconnectDevice(id);
      return;
    }
    lastError = null;
    notifyListeners();
  }

  bool isDeviceConnected(String id) {
    final canonical = canonicalDeviceId(id);
    final device = pairedStore.devices
        .where((candidate) => candidate.id == canonical)
        .firstOrNull;
    return device != null &&
        isDeviceConnectionActive(
          enabled: device.connected,
          online: isDeviceOnline(canonical),
        );
  }

  Future<bool> reconnectDevice(String id, {bool reportError = true}) async {
    if (!_coreNetworkingStarted) return false;
    final canonical = canonicalDeviceId(id);
    final device = pairedStore.devices
        .where((candidate) => candidate.id == canonical)
        .firstOrNull;
    if (device == null || !device.connected) return false;

    final candidates = <Peer>[
      ...peerBrowser.peers.where(
        (peer) => canonicalDeviceId(peer.id) == canonical,
      ),
      if (device.host case final host? when host.isNotEmpty)
        Peer(
          id: canonical,
          name: device.name,
          host: host,
          port: SubnetSweeper.fixedPort,
        ),
    ];

    Peer? matched;
    for (final candidate in candidates) {
      final probed = await SubnetSweeper.probeHost(candidate.host);
      if (probed != null && canonicalDeviceId(probed.id) == canonical) {
        matched = probed;
        break;
      }
    }
    matched ??= matchingReconnectPeer(
      deviceId: canonical,
      mdnsPeers: const [],
      sweptPeers: await SubnetSweeper.sweep(),
    );

    if (matched == null) {
      deviceOnline[canonical] = false;
      if (reportError) lastError = 'That device is not reachable right now.';
      notifyListeners();
      return false;
    }

    await pairedStore.updateHost(canonical, matched.host);
    deviceOnline[canonical] = true;
    lastError = null;
    notifyListeners();
    return true;
  }

  /// Whether [id] answered on the network as of the last liveness refresh.
  bool isDeviceOnline(String id) =>
      deviceOnline[canonicalDeviceId(id)] ?? false;

  /// Rebuilds [deviceOnline]. Device probes run concurrently on a shared client
  /// and try the current mDNS address before the stored fallback.
  Future<void> refreshDeviceLiveness() async {
    if (!_coreNetworkingStarted) return;

    final client = _livenessClient ??= http.Client();
    final next = await computeDeviceLiveness(
      devices: pairedStore.devices,
      mdnsPeers: peerBrowser.peers,
      probe: (host) => SubnetSweeper.probeHost(host, client: client),
    );

    if (mapEquals(deviceOnline, next)) return;
    deviceOnline
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void _startLivenessTimer() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(
      _livenessInterval,
      (_) => unawaited(refreshDeviceLiveness()),
    );
    unawaited(refreshDeviceLiveness());
  }

  void _stopLivenessTimer() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _livenessClient?.close();
    _livenessClient = null;
    if (deviceOnline.isEmpty) return;
    deviceOnline.clear();
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

  // MARK: - File transfer

  /// Resolves the reachable [Peer] for a paired device (mDNS first, then stored host).
  Peer? resolvePeer(String deviceId) {
    final canonical = canonicalDeviceId(deviceId);
    final device = pairedStore.devices
        .where((candidate) => candidate.id == canonical)
        .firstOrNull;
    if (device == null) return null;
    return resolveVerifiedPeer(
      device: device,
      online: isDeviceOnline(canonical),
      mdnsPeers: peerBrowser.peers,
    );
  }

  List<PairedDevice> get reachablePairedDevices =>
      pairedStore.devices.where((d) => resolvePeer(d.id) != null).toList();

  Future<bool> sendFileTo(File file, String deviceId) async {
    final connected = await reconnectDevice(deviceId, reportError: false);
    final peer = connected ? resolvePeer(deviceId) : null;
    if (peer == null) {
      lastError = 'That device is not reachable right now.';
      notifyListeners();
      return false;
    }

    final uiId = const Uuid().v4();
    final token = TransferCancelToken();
    _sendTokens[uiId] = token;
    transfers.insert(
      0,
      FileTransferUiState(
        id: uiId,
        key: uiId,
        fileName: _basename(file.path),
        direction: TransferDirection.sending,
      ),
    );
    _syncWakelock();
    notifyListeners();

    try {
      await fileSender.sendFile(
        file: file,
        peer: peer,
        mimeType: _mimeType(file.path),
        onProgress: (p) => _updateSendProgress(uiId, p),
        isCancelled: () => token.cancelled,
      );
      _completeSend(uiId, TransferStatus.completed);
      return true;
    } on FileSendCancelledException {
      _completeSend(uiId, TransferStatus.cancelled);
      return false;
    } catch (e) {
      _completeSend(uiId, TransferStatus.failed, reason: e.toString());
      return false;
    }
  }

  void cancelTransfer(String uiId) {
    _sendTokens[uiId]?.cancel();
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((t) => !t.isActive);
    notifyListeners();
  }

  /// Keeps the screen awake while any transfer is active (mobile only; foreground
  /// transfers can die if the device sleeps). Best-effort.
  void _syncWakelock() {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    final anyActive = transfers.any((t) => t.isActive);
    WakelockPlus.toggle(enable: anyActive).catchError((_) {});
  }

  void _updateSendProgress(String uiId, double progress) {
    final t = transfers.firstWhere((t) => t.id == uiId, orElse: () => _missing);
    if (identical(t, _missing) || !t.isActive) return;
    t.progress = progress;
    notifyListeners();
  }

  void _completeSend(String uiId, TransferStatus status, {String? reason}) {
    _sendTokens.remove(uiId);
    final t = transfers.firstWhere((t) => t.id == uiId, orElse: () => _missing);
    if (identical(t, _missing)) return;
    if (status == TransferStatus.completed) t.progress = 1.0;
    t.status = status;
    t.reason = reason;
    _syncWakelock();
    notifyListeners();
  }

  @visibleForTesting
  void handleReceiveEvent(FileTransferReceiveEvent event) {
    FileTransferUiState? existing;
    for (final t in transfers) {
      if (t.key == event.transferId &&
          t.direction == TransferDirection.receiving) {
        existing = t;
        break;
      }
    }

    switch (event.type) {
      case 'started':
        if (existing == null) {
          transfers.insert(
            0,
            FileTransferUiState(
              id: const Uuid().v4(),
              key: event.transferId,
              fileName: event.fileName ?? 'file',
              direction: TransferDirection.receiving,
            ),
          );
        }
        break;
      case 'progress':
        if (existing != null && event.total > 0) {
          existing.progress = event.received / event.total;
        }
        break;
      case 'completed':
        if (existing != null) {
          existing.progress = 1.0;
          existing.path = event.path;
          if (event.path == null || !Platform.isAndroid) {
            existing.status = TransferStatus.completed;
            _notifyReceivedFile(
              event.transferId,
              existing.fileName,
              event.path,
            );
          } else {
            unawaited(_publishCompletedAndroidTransfer(existing, event.path!));
          }
        }
        break;
      case 'failed':
        existing?.status = TransferStatus.failed;
        existing?.reason = event.reason;
        break;
      case 'cancelled':
        existing?.status = TransferStatus.cancelled;
        break;
    }
    _syncWakelock();
    notifyListeners();
  }

  Future<void> _publishCompletedAndroidTransfer(
    FileTransferUiState transfer,
    String path,
  ) async {
    try {
      await _androidDownloads.publish(
        sourcePath: path,
        fileName: transfer.fileName,
        mimeType: _mimeType(transfer.fileName),
      );
      transfer.status = TransferStatus.completed;
      _notifyReceivedFile(transfer.key, transfer.fileName, null);
    } catch (_) {
      transfer.status = TransferStatus.failed;
      transfer.reason = 'Could not save this file to Downloads.';
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
      transfer.path = null;
      notifyListeners();
    }
  }

  Future<bool> openDownloads() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _androidDownloads.openDownloads();
    } on PlatformException {
      return false;
    }
  }

  void _notifyReceivedFile(String transferId, String fileName, String? path) {
    if (!_notifiedReceiveIds.add(transferId)) return;
    unawaited(
      _receivedFileNotifications.showReceivedFile(
        transferId: transferId,
        fileName: fileName,
        savedPath: path,
      ),
    );
  }

  /// Android uses an app-private staging directory before MediaStore publishes to
  /// Downloads. iOS keeps completed files in its Files-visible Documents folder.
  Future<Directory> _resolveDestinationDir() async {
    Directory base;
    if (Platform.isAndroid) {
      base = await getApplicationSupportDirectory();
    } else if (Platform.isIOS) {
      base = await getApplicationDocumentsDirectory();
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/Received');
    await dir.create(recursive: true);
    return dir;
  }

  static final FileTransferUiState _missing = FileTransferUiState(
    id: '__missing__',
    key: '__missing__',
    fileName: '',
    direction: TransferDirection.sending,
  );

  String _basename(String path) => path.split('/').last.split('\\').last;

  String _mimeType(String path) {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    const map = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'pdf': 'application/pdf',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'zip': 'application/zip',
      'txt': 'text/plain',
    };
    return map[ext] ?? 'application/octet-stream';
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
    final persisted = <Map<String, dynamic>>[];
    var persistedBytes = 2;
    for (final clip in clips) {
      final encoded = jsonEncode(clip.toJson());
      if (persistedBytes + encoded.length > _maxPersistedClipBytes) {
        continue;
      }
      persisted.add(clip.toJson());
      persistedBytes += encoded.length + 1;
    }
    final clipsJson = jsonEncode(persisted);
    await _prefs.setString(_clipsKey, clipsJson);
  }

  @override
  void dispose() {
    _transferGcTimer?.cancel();
    _livenessTimer?.cancel();
    _livenessClient?.close();
    unawaited(_transferSub?.cancel());
    if (_coreNetworkingStarted) {
      unawaited(peerBrowser.stop());
      unawaited(peerAdvertiser.stop());
      unawaited(clipServer.stop());
      unawaited(fileReceiver.dispose());
    }
    super.dispose();
  }
}
