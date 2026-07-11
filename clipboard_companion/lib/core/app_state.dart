import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
import 'subnet_sweeper.dart';

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
  late FileSender fileSender;
  late FileReceiver fileReceiver;
  late SharedPreferences _prefs;
  bool _coreNetworkingStarted = false;
  bool _discoveryRunning = false;

  StreamSubscription<FileTransferReceiveEvent>? _transferSub;
  Timer? _transferGcTimer;
  final Map<String, TransferCancelToken> _sendTokens = {};

  /// In-flight and finished transfers (both directions), newest first.
  final List<FileTransferUiState> transfers = [];

  static const _clipsKey = 'saved_clips';
  static const _receiveDestinationModeKey = 'receive_dest_mode';
  static const _receiveDestinationPathKey = 'receive_dest_path';
  static const _defaultDestinationMode = 'default';
  static const _askDestinationMode = 'ask';
  String _receiveDestinationMode = '';
  String? _receiveDestinationPath;
  String? pendingDestinationChoicePath;
  String? pendingAskDestinationPath;

  String get receiveDestinationMode => _receiveDestinationMode;

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
    _receiveDestinationMode = prefs.getString(_receiveDestinationModeKey) ?? '';
    _receiveDestinationPath = prefs.getString(_receiveDestinationPathKey);
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
      fileSender = FileSender(identity: identity, pairedStore: pairedStore);

      final tempDir = await getTemporaryDirectory();
      final transfersDir = Directory('${tempDir.path}/Transfers');
      final destinationDir = await _resolveDestinationDir();
      fileReceiver = FileReceiver(
        pairedStore: pairedStore,
        transfersDirectory: transfersDir,
        destinationProvider: () => destinationDir,
      );
      _transferSub = fileReceiver.events.listen(_onReceiveEvent);
      _transferGcTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => fileReceiver.garbageCollect(),
      );

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
        fileReceiver: fileReceiver,
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

  Future<void> setDeviceConnected(String id, bool connected) async {
    await pairedStore.setConnected(id, connected);
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
    final targets = composeSendTargets(peerBrowser.peers, pairedStore.devices);
    for (final peer in targets) {
      if (peer.id == canonical) return peer;
    }
    return null;
  }

  List<PairedDevice> get reachablePairedDevices =>
      pairedStore.devices.where((d) => resolvePeer(d.id) != null).toList();

  Future<void> sendFileTo(File file, String deviceId) async {
    final peer = resolvePeer(deviceId);
    if (peer == null) {
      lastError = 'That device is not reachable right now.';
      notifyListeners();
      return;
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
    } on FileSendCancelledException {
      _completeSend(uiId, TransferStatus.cancelled);
    } catch (e) {
      _completeSend(uiId, TransferStatus.failed, reason: e.toString());
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

  void _onReceiveEvent(FileTransferReceiveEvent event) {
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
          existing.status = TransferStatus.completed;
          existing.path = event.path;
          if (event.path != null)
            unawaited(_postProcessCompletedTransfer(existing, event.path!));
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

  Future<void> _postProcessCompletedTransfer(
    FileTransferUiState transfer,
    String path,
  ) async {
    // iOS keeps files in Documents/Received, which is visible in Files. Android uses
    // its app-scoped directory as a reliable staging area before a user-selected copy.
    if (!Platform.isAndroid) return;
    if (_receiveDestinationMode.isEmpty) {
      pendingDestinationChoicePath = path;
      notifyListeners();
      return;
    }
    if (_receiveDestinationMode == _askDestinationMode) {
      pendingAskDestinationPath = path;
      notifyListeners();
      return;
    }
    if (_receiveDestinationMode == _defaultDestinationMode &&
        _receiveDestinationPath != null) {
      await _copyReceivedFile(transfer, path, _receiveDestinationPath!);
    }
  }

  Future<void> setReceiveDestinationDefault(String directory) async {
    _receiveDestinationMode = _defaultDestinationMode;
    _receiveDestinationPath = directory;
    pendingDestinationChoicePath = null;
    await _prefs.setString(_receiveDestinationModeKey, _receiveDestinationMode);
    await _prefs.setString(_receiveDestinationPathKey, directory);
    notifyListeners();
  }

  Future<void> setReceiveDestinationAskEveryTime() async {
    _receiveDestinationMode = _askDestinationMode;
    pendingDestinationChoicePath = null;
    await _prefs.setString(_receiveDestinationModeKey, _receiveDestinationMode);
    await _prefs.remove(_receiveDestinationPathKey);
    notifyListeners();
  }

  Future<void> keepDefaultReceiveDestination() async {
    await setReceiveDestinationDefault((await _resolveDestinationDir()).path);
  }

  Future<void> movePendingReceivedFileTo(String directory) async {
    final path = pendingAskDestinationPath ?? pendingDestinationChoicePath;
    if (path == null) return;
    final transfer = transfers.where((t) => t.path == path).firstOrNull;
    if (transfer != null) await _copyReceivedFile(transfer, path, directory);
    pendingAskDestinationPath = null;
    notifyListeners();
  }

  Future<void> _copyReceivedFile(
    FileTransferUiState transfer,
    String sourcePath,
    String directory,
  ) async {
    try {
      final destinationDirectory = Directory(directory);
      await destinationDirectory.create(recursive: true);
      final source = File(sourcePath);
      var destination = File('$directory/${_basename(sourcePath)}');
      var suffix = 1;
      while (await destination.exists()) {
        destination = File('$directory/${suffix++}_${_basename(sourcePath)}');
      }
      await source.copy(destination.path);
      transfer.path = destination.path;
      notifyListeners();
    } catch (e) {
      lastError = 'Could not copy received file: $e';
      notifyListeners();
    }
  }

  /// Save location: Android app-scoped external files dir (no SAF), iOS Documents
  /// dir (Files-visible via Info.plist keys), fallback to app support elsewhere.
  Future<Directory> _resolveDestinationDir() async {
    Directory base;
    if (Platform.isAndroid) {
      base =
          (await getExternalStorageDirectory()) ??
          await getApplicationSupportDirectory();
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
    final clipsJson = jsonEncode(clips.map((e) => e.toJson()).toList());
    await _prefs.setString(_clipsKey, clipsJson);
  }

  @override
  void dispose() {
    _transferGcTimer?.cancel();
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
