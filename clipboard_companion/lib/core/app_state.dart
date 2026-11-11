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
import 'replay_guard.dart';
import 'pairing_coordinator.dart';
import 'clip_server.dart';
import 'clip_sender.dart';
import 'file_receiver.dart';
import 'file_sender.dart';
import 'file_transfer_ui.dart';
import 'incoming_share.dart';
import 'android_downloads.dart';
import 'subnet_sweeper.dart';
import 'liveness_ping.dart';
import 'received_file_notifications.dart';

class AsyncOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((_) {});
    return result;
  }
}

/// Lets a flow that backgrounded the app (a system file picker) wait until
/// the resume that follows has restarted networking and re-probed devices:
/// pausing clears liveness, so nothing looks reachable until then.
class ResumeGate {
  Completer<void>? _pending;

  void paused() => _pending ??= Completer<void>();

  Future<void> resumed(Future<void> Function() probe) async {
    final pending = _pending;
    try {
      await probe();
    } finally {
      if (identical(_pending, pending)) _pending = null;
      if (pending != null && !pending.isCompleted) pending.complete();
    }
  }

  /// Completes once the resume after the last pause has finished (at once
  /// when nothing is paused), or after [timeout].
  Future<void> settled({Duration timeout = const Duration(seconds: 5)}) {
    final pending = _pending;
    if (pending == null) return Future<void>.value();
    return pending.future.timeout(timeout, onTimeout: () {});
  }
}

bool isDeviceConnectionActive({required bool enabled, required bool online}) =>
    enabled && online;

Peer? resolveVerifiedPeer({
  required PairedDevice device,
  required bool online,
  required List<Peer> mdnsPeers,
  Set<String> outdatedDeviceIds = const {},
}) {
  if (!isDeviceConnectionActive(enabled: device.connected, online: online)) {
    return null;
  }
  // Never the mDNS-claimed address: only a pong moves the stored host.
  final host = device.host;
  if (host == null || host.isEmpty) return null;
  return storedHostPeer(device, host, outdatedDeviceIds);
}

/// A peer at the device's stored host (the last host that answered a valid pong),
/// carrying an older protocol version when it is in [outdatedDeviceIds].
Peer storedHostPeer(
  PairedDevice device,
  String host,
  Set<String> outdatedDeviceIds,
) {
  final canonical = canonicalDeviceId(device.id);
  return Peer(
    id: canonical,
    name: device.name,
    host: host,
    port: SubnetSweeper.fixedPort,
    protocolVersion: outdatedDeviceIds.contains(canonical)
        ? 1
        : wireProtocolVersion,
  );
}

/// True when a paired device advertises an older wire protocol (via mDNS, or as
/// recorded in [outdatedDeviceIds]): it is listed, but nothing is sent to it.
///
/// An unauthenticated mDNS `v < 2` counts only for devices that have not proved v2
/// with a valid pong ([verifiedOnlineIds]), so a LAN impostor cannot block a live
/// device.
bool deviceNeedsUpdate({
  required String deviceId,
  required List<Peer> mdnsPeers,
  required Set<String> outdatedDeviceIds,
  Set<String> verifiedOnlineIds = const {},
}) {
  final canonical = canonicalDeviceId(deviceId);
  return outdatedDeviceIds.contains(canonical) ||
      (!verifiedOnlineIds.contains(canonical) &&
          mdnsPeers.any(
            (peer) =>
                canonicalDeviceId(peer.id) == canonical && peer.needsUpdate,
          ));
}

List<Peer> composeSendTargets(
  List<Peer> mdnsPeers,
  List<PairedDevice> pairedDevices, {
  Set<String> outdatedDeviceIds = const {},
  Set<String> verifiedOnlineIds = const {},
}) {
  final byId = <String, Peer>{};
  final pairedIds = {
    for (final device in pairedDevices) canonicalDeviceId(device.id),
  };
  // Unpaired mDNS peers only count as visible; the sender has no key for them.
  for (final peer in mdnsPeers) {
    if (!pairedIds.contains(canonicalDeviceId(peer.id))) byId[peer.id] = peer;
  }
  // Paired devices go to their stored (ping-verified) host, never an mDNS-claimed
  // one. An older mDNS `v` keeps them from being sent to, unless a pong proved v2.
  final outdated = {
    ...outdatedDeviceIds,
    for (final peer in mdnsPeers)
      if (peer.needsUpdate &&
          !verifiedOnlineIds.contains(canonicalDeviceId(peer.id)))
        canonicalDeviceId(peer.id),
  };
  for (final device in pairedDevices.where((device) => device.connected)) {
    final host = device.host;
    if (host != null && host.isNotEmpty) {
      byId[device.id] = storedHostPeer(device, host, outdated);
    }
  }
  return byId.values.toList();
}

/// Outcome of pinging paired devices: who answered a valid pong, and where.
class LivenessReport {
  /// Canonical ids of devices that answered a valid pong, keyed to the host that
  /// answered.
  final Map<String, String> verifiedHosts = {};

  /// Canonical ids of devices that answered 426 and no valid pong.
  final Set<String> upgradeRequired = {};

  /// Canonical ids of devices that answered `400 stale` (clock out of sync) and no
  /// valid pong.
  final Set<String> clockSkew = {};

  Set<String> get onlineIds => verifiedHosts.keys.toSet();

  void merge(LivenessReport other) {
    other.verifiedHosts.forEach(
      (id, host) => verifiedHosts.putIfAbsent(id, () => host),
    );
    upgradeRequired
      ..addAll(other.upgradeRequired)
      ..removeAll(verifiedHosts.keys);
    clockSkew
      ..addAll(other.clockSkew)
      ..removeAll(verifiedHosts.keys);
  }
}

/// Pings one paired device at one host.
typedef DevicePing =
    Future<PingOutcome> Function(PairedDevice device, String host);

/// Hosts to ping for a device: its current mDNS address(es), then the stored one.
List<String> candidateHosts(PairedDevice device, List<Peer> mdnsPeers) {
  final id = canonicalDeviceId(device.id);
  final hosts = mdnsPeers
      .where((peer) => canonicalDeviceId(peer.id) == id)
      .map((peer) => peer.host)
      .toList();
  final host = device.host;
  if (host != null && host.isNotEmpty && !hosts.contains(host)) {
    hosts.add(host);
  }
  return hosts;
}

/// Pings [hosts] in order and stops at the first valid pong.
Future<LivenessReport> verifyDevice(
  PairedDevice device,
  List<String> hosts,
  DevicePing ping,
) async {
  final id = canonicalDeviceId(device.id);
  final report = LivenessReport();
  for (final host in hosts) {
    switch (await ping(device, host)) {
      case PingOutcome.alive:
        report.verifiedHosts[id] = host;
        report.upgradeRequired.remove(id);
        report.clockSkew.remove(id);
        return report;
      case PingOutcome.upgradeRequired:
        report.upgradeRequired.add(id);
      case PingOutcome.clockSkew:
        report.clockSkew.add(id);
      case PingOutcome.unverified:
        break;
    }
  }
  return report;
}

/// Resolves which paired devices are reachable right now, and where. mDNS and the
/// stored address only nominate hosts; a device is online only at a host that
/// answered a valid pong (see [LivenessPing]). Independent of
/// [PairedDevice.connected], which is a local pause switch rather than a statement
/// about reachability.
Future<LivenessReport> computeDeviceLiveness({
  required List<PairedDevice> devices,
  required List<Peer> mdnsPeers,
  required DevicePing ping,
}) async {
  final report = LivenessReport();
  final partials = await Future.wait(
    devices.map(
      (device) => verifyDevice(device, candidateHosts(device, mdnsPeers), ping),
    ),
  );
  for (final partial in partials) {
    report.merge(partial);
  }
  return report;
}

/// Stored-host changes a report calls for: devices whose pong came from a host
/// other than the one stored.
Map<String, String> hostUpdates(
  List<PairedDevice> devices,
  LivenessReport report,
) => {
  for (final device in devices)
    if (report.verifiedHosts[canonicalDeviceId(device.id)] case final host?
        when host != device.host)
      canonicalDeviceId(device.id): host,
};

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

/// Whether the incoming-share prompt should be presented for [batch] right now.
///
/// A batch is offered at most once: the prompt is driven from `build`, so a batch
/// that stays pending after being handled reopens the sheet on every rebuild and
/// traps the user in a loop they can only escape by killing the app.
bool shouldPromptForShareBatch({
  required IncomingShareBatch? batch,
  required bool isReady,
  required bool promptVisible,
  required Set<String> handledBatchIds,
}) =>
    batch != null &&
    isReady &&
    !promptVisible &&
    !handledBatchIds.contains(batch.id);

/// Outcome of sending one shared batch, so the UI can report partial failures.
class ShareSendResult {
  final int sent;
  final int failed;

  const ShareSendResult({required this.sent, required this.failed});

  int get total => sent + failed;
  bool get hasFailures => failed > 0;
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
  StreamSubscription<List<Peer>>? _peersSub;
  Timer? _transferGcTimer;
  Timer? _livenessTimer;
  http.Client? _livenessClient;
  final AsyncOperationQueue _networkTransitions = AsyncOperationQueue();
  final ResumeGate _resumeGate = ResumeGate();
  Future<void>? _startupLivenessProbe;

  /// Live reachability per paired device id. In-memory only: it is rebuilt from
  /// scratch on every refresh, so unpaired devices drop out on their own.
  final Map<String, bool> deviceOnline = {};

  /// Paired devices that answered a ping with 426 (or, found only by the reconnect
  /// sweep, advertised an older `v` on `/v1/id`). A valid pong clears the flag.
  final Set<String> outdatedDeviceIds = {};

  /// Paired devices whose last ping was refused as stale: their clock disagrees with
  /// ours. Shown as "Clock out of sync"; never makes a device online or moves its host.
  final Set<String> clockSkewDeviceIds = {};

  /// One guard for every envelope endpoint, kept across network restarts, so a nonce
  /// is single-use for the whole process.
  final ReplayGuard _replayGuard = ReplayGuard();
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

  /// The number to compare while this device is the pairing target.
  PairingComparison? get hostComparison =>
      _coreNetworkingStarted ? pairingCoordinator.hostComparison : null;

  /// The number to compare while this device is the pairing initiator.
  PairingComparison? get joinComparison =>
      _coreNetworkingStarted ? pairingCoordinator.joinComparison : null;

  /// Devices found by the last "Scan network" (subnet sweep).
  List<Peer> sweptPeers = const [];
  bool scanInProgress = false;

  /// Devices the user can pick to pair with: discovered, not paired yet, and on v2.
  List<Peer> get pairingCandidates {
    if (!_coreNetworkingStarted) return const [];
    final paired = {
      for (final device in pairedStore.devices) canonicalDeviceId(device.id),
    };
    return composeJoinCandidates(peerBrowser.peers, sweptPeers)
        .where(
          (peer) =>
              !peer.needsUpdate && !paired.contains(canonicalDeviceId(peer.id)),
        )
        .toList();
  }

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
    await pairedStore.quarantineIfCorrupt();
    if (pairedStore.quarantinedKey != null) {
      // One-time notice: the unreadable list was moved aside, so this shows once.
      lastError =
          'Saved paired devices could not be read and were reset. Pair your devices again.';
    }
    try {
      await pairedStore.migrateLegacyKeys();
    } catch (e) {
      // Keys stay in prefs and getKey retries the move on next use.
      debugPrint('Pair key migration deferred: ${e.runtimeType}');
    }
    _loadClips();
    if (Platform.isAndroid || Platform.isIOS) {
      _shareChannel.setMethodCallHandler(_handleShareMethod);
      final initial = await _shareChannel.invokeMapMethod<Object?, Object?>(
        'getInitialShare',
      );
      if (initial != null) stageIncomingShare(initial);
    }
    notifyListeners();
  }

  Future<Object?> _handleShareMethod(MethodCall call) async {
    if (call.method == 'incomingShare' && call.arguments is Map) {
      stageIncomingShare(Map<Object?, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  @visibleForTesting
  void stageIncomingShare(Map<Object?, Object?> value) {
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

  /// Sends every attachment of the pending batch, then consumes the batch.
  ///
  /// The batch is consumed whether or not the sends worked: failures are already
  /// reported through [transfers] and [lastError], and leaving a handled batch
  /// pending makes the share prompt reopen on every rebuild.
  Future<ShareSendResult?> sendPendingShareTo(String deviceId) async {
    final batch = pendingShareBatch;
    if (batch == null || isSendingBatch) return null;
    isSendingBatch = true;
    notifyListeners();
    var sent = 0;
    var failed = 0;
    try {
      for (final attachment in batch.attachments) {
        if (!attachment.file.existsSync()) {
          failed++;
          continue;
        }
        if (await sendFileTo(attachment.file, deviceId)) {
          sent++;
        } else {
          failed++;
        }
      }
    } finally {
      isSendingBatch = false;
      await dismissPendingShare();
      notifyListeners();
    }
    return ShareSendResult(sent: sent, failed: failed);
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
        localDeviceId: identity.id,
        transfersDirectory: transfersDir,
        destinationProvider: () => destinationDir,
        replayGuard: _replayGuard,
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
        replayGuard: _replayGuard,
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
      // The pairing card shows the hosted code, the number to compare and the
      // devices to pair with; refresh it when any of them changes.
      pairingCoordinator.onHostingChanged = notifyListeners;
      _peersSub = peerBrowser.peersStream.listen((_) => notifyListeners());
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

  /// Sweeps the local subnet for devices mDNS missed, so the user can pick one.
  Future<void> scanForDevices() async {
    if (scanInProgress) return;
    scanInProgress = true;
    notifyListeners();
    try {
      sweptPeers = await SubnetSweeper.sweep();
    } finally {
      scanInProgress = false;
      notifyListeners();
    }
  }

  /// Starts pairing with the one device the user selected. On success both
  /// screens show a number; the user then calls [confirmJoin] or [cancelJoin].
  Future<void> joinWithCode(String code, Peer peer) async {
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
      await pairingCoordinator.startPairing(peer, normalizedCode);
    } catch (e) {
      lastError = joinErrorMessage(e);
    } finally {
      joinInProgress = false;
      notifyListeners();
    }
  }

  /// The user confirmed the numbers match on this device.
  Future<void> confirmJoin() async {
    joinInProgress = true;
    lastError = null;
    notifyListeners();
    try {
      await pairingCoordinator.confirmPairing();
      unawaited(refreshDeviceLiveness());
    } on PairingCancelledException {
      // The user cancelled here; nothing to report.
    } catch (e) {
      lastError = joinErrorMessage(e);
    } finally {
      joinInProgress = false;
      notifyListeners();
    }
  }

  void cancelJoin() => unawaited(pairingCoordinator.cancelPairing());

  void confirmHostedPairing() => pairingCoordinator.confirmHostedPairing();

  void cancelHostedPairing() => pairingCoordinator.cancelHostedPairing();

  static const alreadyPairedMessage =
      'Remove the existing pairing on the other device first';

  static String joinErrorMessage(Object error) => switch (error) {
    PairingAlreadyPairedException() => alreadyPairedMessage,
    PairingTimedOutException() =>
      'The other device did not confirm in time. Show a new code and try again.',
    PairingNotAcceptedException() =>
      'The other device did not accept. Check the code, or show a new one, and try again.',
    _ =>
      'Could not reach that device. Make sure it is showing a code on the same Wi-Fi.',
  };

  Future<void> pauseSyncServices() {
    _resumeGate.paused();
    return _enqueueNetworkTransition(_pauseSyncServices);
  }

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

  /// Pings the device at its mDNS and stored addresses; failing that, sweeps the
  /// subnet for hosts claiming its id on `/v1/id` and pings those. Only a valid pong
  /// makes it online or moves its stored host.
  Future<bool> reconnectDevice(String id, {bool reportError = true}) async {
    if (!_coreNetworkingStarted) return false;
    final canonical = canonicalDeviceId(id);
    final device = pairedStore.devices
        .where((candidate) => candidate.id == canonical)
        .firstOrNull;
    if (device == null || !device.connected) return false;

    final client = http.Client();
    try {
      final ping = _devicePing(client);
      final tried = candidateHosts(device, peerBrowser.peers);
      final report = await verifyDevice(device, tried, ping);
      if (!report.verifiedHosts.containsKey(canonical)) {
        final claimed = (await SubnetSweeper.sweep(
          client: client,
        )).where((peer) => canonicalDeviceId(peer.id) == canonical).toList();
        report.merge(
          await verifyDevice(
            device,
            claimed
                .map((peer) => peer.host)
                .where((host) => !tried.contains(host))
                .toList(),
            ping,
          ),
        );
        // A v1 peer cannot answer a ping; its advertised version is the only signal.
        if (!report.verifiedHosts.containsKey(canonical) &&
            claimed.any((peer) => peer.needsUpdate)) {
          report.upgradeRequired.add(canonical);
        }
      }

      final stored = await _applyLiveness(report, [device], rebuildAll: false);
      if (!report.verifiedHosts.containsKey(canonical)) {
        if (reportError) lastError = unreachableMessage(canonical);
        notifyListeners();
        return false;
      }
      // Keep a failed stored-host update visible.
      if (stored) lastError = null;
      notifyListeners();
      return true;
    } finally {
      client.close();
    }
  }

  /// Pings one paired device at one host over `POST /v1/ping` on [client].
  DevicePing _devicePing(http.Client client) => (device, host) async {
    final key = await pairedStore.getKey(device.id);
    if (key == null) return PingOutcome.unverified;
    return LivenessPing.ping(
      deviceId: device.id,
      localDeviceId: identity.id,
      pairKey: key,
      post: (body) => SubnetSweeper.postPing(host, body, client: client),
    );
  };

  /// The only place a paired device becomes online, has its stored host changed, or
  /// has its outdated flag changed, and only from ping results: `/v1/id` and mDNS
  /// nominate hosts but never prove identity. With [rebuildAll], [deviceOnline] is
  /// rebuilt from [devices] (so unpaired devices drop out); otherwise only [devices]
  /// are updated. Returns false when a stored-host update failed (its error is left
  /// in [lastError]); storage errors never escape, since the liveness timer calls this.
  Future<bool> _applyLiveness(
    LivenessReport report,
    List<PairedDevice> devices, {
    required bool rebuildAll,
  }) async {
    var changed = false;
    var stored = true;
    for (final MapEntry(key: id, value: host) in hostUpdates(
      devices,
      report,
    ).entries) {
      try {
        await pairedStore.updateHost(id, host);
      } catch (e) {
        stored = false;
        lastError = 'Could not save the device address: $e';
      }
      changed = true;
    }

    final outdated = {...outdatedDeviceIds}
      ..removeAll(report.onlineIds)
      ..addAll(report.upgradeRequired);
    if (!setEquals(outdated, outdatedDeviceIds)) {
      outdatedDeviceIds
        ..clear()
        ..addAll(outdated);
      changed = true;
    }

    final skewed = {
      if (!rebuildAll)
        ...clockSkewDeviceIds.difference({
          for (final device in devices) canonicalDeviceId(device.id),
        }),
      ...report.clockSkew,
    };
    if (!setEquals(skewed, clockSkewDeviceIds)) {
      clockSkewDeviceIds
        ..clear()
        ..addAll(skewed);
      changed = true;
    }

    final next = <String, bool>{
      if (!rebuildAll) ...deviceOnline,
      for (final device in devices)
        canonicalDeviceId(device.id): report.onlineIds.contains(
          canonicalDeviceId(device.id),
        ),
    };
    if (!mapEquals(deviceOnline, next)) {
      deviceOnline
        ..clear()
        ..addAll(next);
      changed = true;
    }
    if (changed) notifyListeners();
    return stored;
  }

  /// Canonical ids of pong-verified (online) devices.
  Set<String> get _verifiedOnlineIds => {
    for (final entry in deviceOnline.entries)
      if (entry.value) entry.key,
  };

  /// Whether [id] advertises an older wire protocol (see [deviceNeedsUpdate]).
  bool isDeviceOutdated(String id) => deviceNeedsUpdate(
    deviceId: id,
    mdnsPeers: _coreNetworkingStarted ? peerBrowser.peers : const [],
    outdatedDeviceIds: outdatedDeviceIds,
    verifiedOnlineIds: _verifiedOnlineIds,
  );

  /// Whether [id]'s last ping was refused as stale (clocks out of sync).
  bool isDeviceClockSkewed(String id) =>
      clockSkewDeviceIds.contains(canonicalDeviceId(id));

  /// Why a device cannot be sent to right now, for reconnect and file-send errors.
  String unreachableMessage(String id) {
    if (isDeviceOutdated(id)) return updateOtherDeviceMessage;
    if (isDeviceClockSkewed(id)) {
      final canonical = canonicalDeviceId(id);
      final device = pairedStore.devices
          .where((candidate) => candidate.id == canonical)
          .firstOrNull;
      return clockOutOfSyncMessage([device?.name ?? canonical]);
    }
    return 'That device is not reachable right now.';
  }

  /// Whether [id] answered on the network as of the last liveness refresh.
  bool isDeviceOnline(String id) =>
      deviceOnline[canonicalDeviceId(id)] ?? false;

  /// Rebuilds [deviceOnline] from authenticated pings. Devices are pinged
  /// concurrently on a shared client, trying the current mDNS address before the
  /// stored one.
  Future<void> refreshDeviceLiveness() async {
    if (!_coreNetworkingStarted) return;

    final client = _livenessClient ??= http.Client();
    final devices = pairedStore.devices;
    final report = await computeDeviceLiveness(
      devices: devices,
      mdnsPeers: peerBrowser.peers,
      ping: _devicePing(client),
    );
    await _applyLiveness(report, devices, rebuildAll: true);
  }

  void _startLivenessTimer() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(
      _livenessInterval,
      (_) => unawaited(refreshDeviceLiveness()),
    );
    final probe = refreshDeviceLiveness();
    _startupLivenessProbe = probe;
    unawaited(probe);
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

  Future<void> resumeSyncServices() => _resumeGate.resumed(() async {
    await startSyncServices();
    await _startupLivenessProbe;
  });

  /// Completes once a pending resume has restarted sync and re-probed device
  /// liveness (immediately if the app was not paused).
  Future<void> whenResumeSettled() => _resumeGate.settled();

  /// Adds a clip this device sends to the local history, unless it is already
  /// there (re-sending an existing clip).
  void recordOutgoingClip(ClipPayload clip) {
    if (clips.any((existing) => existing.id == clip.id)) return;
    clips.insert(0, clip);
    _saveClips();
    notifyListeners();
  }

  Future<ClipSendSummary> sendClip(ClipPayload clip) async {
    recordOutgoingClip(clip);

    // Broadcast
    final targets = composeSendTargets(
      peerBrowser.peers,
      pairedStore.devices,
      outdatedDeviceIds: outdatedDeviceIds,
      verifiedOnlineIds: _verifiedOnlineIds,
    );
    return clipSender.broadcast(clip, targets);
  }

  // MARK: - File transfer

  /// Resolves the reachable [Peer] for a paired device at its ping-verified stored host.
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
      outdatedDeviceIds: outdatedDeviceIds,
    );
  }

  List<PairedDevice> get reachablePairedDevices =>
      pairedStore.devices.where((d) => resolvePeer(d.id) != null).toList();

  Future<bool> sendFileTo(File file, String deviceId) async {
    final connected = await reconnectDevice(deviceId, reportError: false);
    // Checked after the reconnect probe, which records the advertised version.
    if (isDeviceOutdated(deviceId)) {
      lastError = updateOtherDeviceMessage;
      notifyListeners();
      return false;
    }
    final peer = connected ? resolvePeer(deviceId) : null;
    if (peer == null) {
      lastError = unreachableMessage(deviceId);
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
    unawaited(_peersSub?.cancel());
    if (_coreNetworkingStarted) {
      unawaited(peerBrowser.stop());
      unawaited(peerAdvertiser.stop());
      unawaited(clipServer.stop());
      unawaited(fileReceiver.dispose());
    }
    super.dispose();
  }
}
