using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using ClipboardSS.App.Net;
using ClipboardSS.App.Notifications;
using ClipboardSS.App.Pairing;
using ClipboardSS.App.Settings;
using ClipboardSS.App.UI;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App;

public sealed class AppModel : INotifyPropertyChanged, IClipServerBackend, IDisposable
{
    private readonly ClipboardInterop _clipboard;
    private readonly ClipboardWriter _writer;
    private readonly ClipReceiver _receiver;
    private readonly ClipSender _sender;
    private readonly FileSender _fileSender;
    private readonly FileReceiver _fileReceiver;
    private readonly SettingsStore _settings;
    private readonly IReceivedFileNotificationService _receivedFileNotifications;
    private readonly HashSet<string> _notifiedReceiveIds = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CancellationTokenSource> _fileCancellations = [];
    private const int MaxTransfers = 100;
    private readonly List<FileTransferProgress> _transfers = [];
    private readonly MdnsService _mdns;
    private readonly SubnetSweeper _sweeper;
    private readonly HashSet<Guid> _onlineDevices = [];
    /// <summary>
    /// Paired devices that answered a ping with 426 (or, found only by the reconnect sweep, advertised
    /// an older <c>v</c> on <c>/v1/id</c>). A valid pong clears the flag.
    /// </summary>
    private readonly HashSet<Guid> _outdatedDevices = [];
    /// <summary>
    /// Paired devices whose last ping was refused as stale: their clock disagrees with ours. Shown as
    /// "Clock out of sync"; never makes a device online or moves its host.
    /// </summary>
    private readonly HashSet<Guid> _clockSkewDevices = [];
    private readonly System.Threading.Timer _livenessTimer;
    private readonly SemaphoreSlim _livenessRefreshLock = new(1, 1);
    private CancellationTokenSource? _clipboardDebounce;
    /// <summary>Cancels in-flight clip sends only when the app shuts down.</summary>
    private readonly CancellationTokenSource _lifetime = new();
    private string? _lastWrittenHash;
    private Guid? _lastBroadcastClipId;
    private string? _lastError;
    private IReadOnlyList<Peer> _sweptPeers = [];
    private bool _isScanning;
    private bool _isSyncPaused;
    private bool _disposed;

    public AppModel(
        ClipStore store,
        ClipboardInterop clipboard,
        PairingCoordinator pairingCoordinator,
        ClipSender sender,
        MdnsService mdns,
        SubnetSweeper sweeper,
        FileSender fileSender,
        FileReceiver fileReceiver,
        SettingsStore settings,
        IReceivedFileNotificationService receivedFileNotifications)
    {
        Store = store;
        PairingCoordinator = pairingCoordinator;
        _clipboard = clipboard;
        _writer = new ClipboardWriter(clipboard, store);
        _receiver = new ClipReceiver(store, clipboard, new WicImageValidator());
        _sender = sender;
        _mdns = mdns;
        _sweeper = sweeper;
        _fileSender = fileSender;
        _fileReceiver = fileReceiver;
        _settings = settings;
        _receivedFileNotifications = receivedFileNotifications;
        _livenessTimer = new System.Threading.Timer(
            _ => _ = RefreshDeviceLivenessAsync(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        _fileReceiver.TransferChanged += UpdateTransfer;
        _clipboard.Changed += ClipboardChanged;
        _mdns.PeersChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(VisiblePeers));
            _ = RefreshDeviceLivenessAsync();
        };
        PairingCoordinator.HostingChanged += (_, _) => PairingStateChanged?.Invoke(this, EventArgs.Empty);
        PairingCoordinator.PairedDevicesChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PairedDevices));
            StateChanged?.Invoke(this, EventArgs.Empty);
            _ = RefreshDeviceLivenessAsync();
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? StateChanged;
    /// <summary>The hosted code or a number to compare changed; raised on any thread.</summary>
    public event EventHandler? PairingStateChanged;
    public event EventHandler? DevicesRequested;
    public event Action<PasteRequest>? PasteRequested;
    public ClipStore Store { get; }
    public PairingCoordinator PairingCoordinator { get; }
    public IReadOnlyList<ClipItem> Clips => Store.Items;
    public IReadOnlyList<Peer> VisiblePeers => _mdns.Peers;
    public IReadOnlyList<PairedDevice> PairedDevices => PairingCoordinator.PairedStore.Devices;
    public IReadOnlyList<FileTransferProgress> Transfers => _transfers;

    public string? LastError
    {
        get => _lastError;
        private set
        {
            if (_lastError == value) return;
            _lastError = value;
            OnPropertyChanged();
        }
    }

    public bool IsSyncPaused
    {
        get => _isSyncPaused;
        set
        {
            if (_isSyncPaused == value) return;
            _isSyncPaused = value;
            _livenessTimer.Change(
                value ? Timeout.InfiniteTimeSpan : TimeSpan.Zero,
                value ? Timeout.InfiniteTimeSpan : TimeSpan.FromSeconds(5));
            if (!value) _ = RefreshDeviceLivenessAsync();
            OnPropertyChanged();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Start()
    {
        _ = _mdns.Start();
        _livenessTimer.Change(TimeSpan.Zero, TimeSpan.FromSeconds(5));
        Refresh();
    }

    public void Refresh()
    {
        Store.CleanupExpiredClips();
        OnPropertyChanged(nameof(Clips));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Copy(ClipItem clip)
    {
        _ = TryCopy(clip);
    }

    public void CopyText(string text)
    {
        try
        {
            _clipboard.ClearContents();
            _clipboard.WriteText(text);
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
        }
    }

    public ClipItem AddScreenshot(byte[] pngData)
    {
        var clip = Store.AddImageData(pngData, "png", "Screenshot");
        Refresh();
        return clip;
    }

    public void Paste(ClipItem clip, PasteMode mode)
    {
        if (TryCopy(clip)) PasteRequested?.Invoke(new PasteRequest(clip, mode));
    }

    private bool TryCopy(ClipItem clip)
    {
        try
        {
            _lastWrittenHash = clip.ContentHash;
            _writer.Copy(clip);
            Refresh();
            return true;
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            return false;
        }
    }

    public void ReportError(string message) => LastError = message;
    public void ClearError() => LastError = null;

    public void Delete(ClipItem clip)
    {
        Store.Delete(clip.Id);
        Refresh();
    }

    public void SetPinned(ClipItem clip, bool pinned)
    {
        Store.SetPinned(clip.Id, pinned);
        Refresh();
    }

    public string ShowPairingCode() => PairingCoordinator.StartHosting();
    public void StopHostingCode() => PairingCoordinator.StopHosting();

    /// <summary>Devices the user can pick to pair with: discovered, not paired yet, and on protocol v2.</summary>
    public IReadOnlyList<Peer> PairingCandidates
    {
        get
        {
            var paired = PairedDevices.Select(device => device.Id).ToHashSet();
            return ComposeJoinCandidates(VisiblePeers, _sweptPeers)
                .Where(peer => !peer.NeedsUpdate && !paired.Contains(peer.Id))
                .ToArray();
        }
    }

    public bool IsScanning => _isScanning;

    /// <summary>Sweeps the local subnet for devices mDNS missed, so the user can pick one to pair with.</summary>
    public async Task ScanForDevicesAsync(CancellationToken cancellationToken = default)
    {
        if (_isScanning) return;
        _isScanning = true;
        PairingStateChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            _sweptPeers = await _sweeper.SweepAsync(cancellationToken);
        }
        finally
        {
            _isScanning = false;
            PairingStateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Starts pairing with the one device the user selected. On success both screens show a number;
    /// the user then calls <see cref="ConfirmJoinAsync"/> or <see cref="CancelJoin"/>.
    /// </summary>
    public async Task<bool> JoinWithCodeAsync(string code, Peer peer, CancellationToken cancellationToken = default)
    {
        if (code.Length != 6 || code.Any(character => !char.IsAsciiDigit(character)))
        {
            LastError = "Enter a 6-digit pairing code.";
            return false;
        }

        LastError = null;
        try
        {
            await PairingCoordinator.StartPairingAsync(peer, code, cancellationToken);
            return true;
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            LastError = JoinErrorMessage(exception);
            return false;
        }
    }

    /// <summary>The user confirmed the numbers match on this device.</summary>
    public async Task<bool> ConfirmJoinAsync(CancellationToken cancellationToken = default)
    {
        LastError = null;
        try
        {
            await PairingCoordinator.ConfirmPairingAsync(cancellationToken);
            OnPropertyChanged(nameof(PairedDevices));
            StateChanged?.Invoke(this, EventArgs.Empty);
            return true;
        }
        catch (PairingCancelledException)
        {
            // The user cancelled here; nothing to report.
            return false;
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            LastError = JoinErrorMessage(exception);
            return false;
        }
    }

    public void CancelJoin() => _ = PairingCoordinator.CancelPairingAsync();
    public void ConfirmHostedPairing() => PairingCoordinator.ConfirmHostedPairing();
    public void CancelHostedPairing() => PairingCoordinator.CancelHostedPairing();

    public static string JoinErrorMessage(Exception exception) => exception switch
    {
        PairingAlreadyPairedException or PairingTimedOutException or PairingNotAcceptedException => exception.Message,
        _ => "Could not reach that device. Make sure it is showing a code on the same Wi-Fi.",
    };

    public void Unpair(Guid deviceId)
    {
        PairingCoordinator.PairedStore.RemoveDevice(deviceId);
        lock (_onlineDevices) _onlineDevices.Remove(deviceId);
        OnPropertyChanged(nameof(PairedDevices));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetConnected(Guid deviceId, bool connected)
    {
        _ = SetConnectedAsync(deviceId, connected);
    }

    public async Task SetConnectedAsync(Guid deviceId, bool connected, CancellationToken cancellationToken = default)
    {
        if (connected)
            lock (_onlineDevices) _onlineDevices.Remove(deviceId);
        PairingCoordinator.PairedStore.SetConnected(deviceId, connected);
        if (connected)
            await ReconnectDeviceAsync(deviceId, true, cancellationToken);
        else
            LastError = null;
        OnPropertyChanged(nameof(PairedDevices));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool IsDeviceConnected(Guid deviceId) => PairingCoordinator.PairedStore.IsConnected(deviceId);
    public bool IsDeviceConnectionActive(Guid deviceId) =>
        IsDeviceConnectionActive(IsDeviceConnected(deviceId), IsDeviceOnline(deviceId));

    public static bool IsDeviceConnectionActive(bool enabled, bool online) => enabled && online;

    public static Peer? ResolveVerifiedPeer(
        PairedDevice device,
        bool online,
        IEnumerable<Peer> mdnsPeers,
        IReadOnlySet<Guid>? outdatedDeviceIds = null)
    {
        if (!IsDeviceConnectionActive(device.Connected, online)) return null;
        // Never the mDNS-claimed address: only a pong moves the stored host.
        return string.IsNullOrWhiteSpace(device.Host)
            ? null
            : StoredHostPeer(device, device.Host!, outdatedDeviceIds);
    }

    /// <summary>
    /// A peer at the device's stored host (the last host that answered a valid pong), carrying an
    /// older protocol version when it is in <paramref name="outdatedDeviceIds"/>.
    /// </summary>
    public static Peer StoredHostPeer(PairedDevice device, string host, IReadOnlySet<Guid>? outdatedDeviceIds) =>
        new(device.Id, device.Name, host, 51888,
            outdatedDeviceIds?.Contains(device.Id) == true ? 1 : WireProtocol.Version);

    private HashSet<Guid> OutdatedDeviceSnapshot()
    {
        lock (_outdatedDevices) return [.. _outdatedDevices];
    }

    /// <summary>
    /// Pings the device at its mDNS and stored addresses; failing that, sweeps the subnet for hosts
    /// claiming its id on <c>/v1/id</c> and pings those. Only a valid pong makes it online or moves
    /// its stored host.
    /// </summary>
    public async Task<bool> ReconnectDeviceAsync(
        Guid deviceId,
        bool reportError = true,
        CancellationToken cancellationToken = default)
    {
        var device = PairedDevices.FirstOrDefault(candidate => candidate.Id == deviceId);
        if (device is null || !device.Connected) return false;

        var tried = DeviceLiveness.CandidateHosts(device, VisiblePeers);
        var report = await DeviceLiveness.VerifyAsync(device, tried, PingDeviceAsync, cancellationToken);
        if (!report.VerifiedHosts.ContainsKey(deviceId))
        {
            var claimed = (await _sweeper.SweepAsync(cancellationToken)).Where(peer => peer.Id == deviceId).ToArray();
            report.Merge(await DeviceLiveness.VerifyAsync(
                device,
                claimed.Select(peer => peer.Host).Where(host => !tried.Contains(host, StringComparer.OrdinalIgnoreCase)),
                PingDeviceAsync,
                cancellationToken));
            // A v1 peer cannot answer a ping; its advertised version is the only signal.
            if (!report.VerifiedHosts.ContainsKey(deviceId) && claimed.Any(peer => peer.NeedsUpdate))
                report.UpgradeRequired.Add(deviceId);
        }

        var stored = ApplyLiveness(report, [device], rebuildAll: false);
        if (!report.VerifiedHosts.ContainsKey(deviceId))
        {
            if (reportError) LastError = UnreachableMessage(deviceId);
            StateChanged?.Invoke(this, EventArgs.Empty);
            return false;
        }
        if (stored) LastError = null;
        return true;
    }

    /// <summary>Pings one paired device at one host over <c>POST /v1/ping</c>.</summary>
    private Task<PingOutcome> PingDeviceAsync(PairedDevice device, string host, CancellationToken cancellationToken)
    {
        byte[]? key;
        // A key-storage read failure is no evidence for this device; the others proceed.
        try { key = PairingCoordinator.PairedStore.GetKey(device.Id); }
        catch (Exception) { return Task.FromResult(PingOutcome.Unverified); }
        return key is null
            ? Task.FromResult(PingOutcome.Unverified)
            : _sweeper.PingHostAsync(host, device.Id, PairingCoordinator.Identity.Id, key, cancellationToken);
    }

    /// <summary>
    /// The only place a paired device becomes online, has its stored host changed, or has its outdated
    /// flag changed, and only from ping results: <c>/v1/id</c> and mDNS nominate hosts but never prove
    /// identity. With <paramref name="rebuildAll"/> the online set is rebuilt from the report (so unpaired
    /// devices drop out); otherwise only <paramref name="devices"/> are updated. A stored-host update
    /// that fails is reported in <see cref="LastError"/> and returns false; storage errors never escape the
    /// liveness timer.
    /// </summary>
    private bool ApplyLiveness(LivenessReport report, IReadOnlyCollection<PairedDevice> devices, bool rebuildAll)
    {
        var hostUpdates = DeviceLiveness.HostUpdates(devices, report);
        var storeError = DeviceLiveness.StoreHostUpdates(hostUpdates, PairingCoordinator.PairedStore.UpdateHost);
        if (storeError is not null) LastError = storeError;

        lock (_outdatedDevices)
        {
            _outdatedDevices.ExceptWith(report.OnlineIds);
            _outdatedDevices.UnionWith(report.UpgradeRequired);
        }
        lock (_clockSkewDevices)
        {
            if (rebuildAll) _clockSkewDevices.Clear();
            else _clockSkewDevices.ExceptWith(devices.Select(device => device.Id));
            _clockSkewDevices.UnionWith(report.ClockSkew);
        }

        var changed = hostUpdates.Count > 0;
        lock (_onlineDevices)
        {
            var next = rebuildAll ? [] : new HashSet<Guid>(_onlineDevices);
            next.ExceptWith(devices.Select(device => device.Id));
            next.UnionWith(report.OnlineIds);
            if (!_onlineDevices.SetEquals(next))
            {
                _onlineDevices.Clear();
                _onlineDevices.UnionWith(next);
                changed = true;
            }
        }
        if (hostUpdates.Count > 0) OnPropertyChanged(nameof(PairedDevices));
        if (changed) StateChanged?.Invoke(this, EventArgs.Empty);
        return storeError is null;
    }

    /// <summary>True when the device advertises an older wire protocol: listed, but nothing is sent to it.</summary>
    public bool DeviceNeedsUpdate(Guid deviceId)
    {
        var online = OnlineDeviceSnapshot();
        lock (_outdatedDevices)
        {
            return DeviceNeedsUpdate(deviceId, VisiblePeers, _outdatedDevices, online);
        }
    }

    /// <summary>True when the device's last ping was refused as stale (clocks out of sync).</summary>
    public bool DeviceClockSkewed(Guid deviceId)
    {
        lock (_clockSkewDevices) return _clockSkewDevices.Contains(deviceId);
    }

    /// <summary>Why a device cannot be sent to right now, for reconnect and file-send errors.</summary>
    public string UnreachableMessage(Guid deviceId)
    {
        if (DeviceNeedsUpdate(deviceId)) return WireProtocol.UpdateOtherDeviceMessage;
        if (DeviceClockSkewed(deviceId))
        {
            var name = PairedDevices.FirstOrDefault(device => device.Id == deviceId)?.Name ?? deviceId.ToString("D");
            return WireProtocol.ClockOutOfSyncMessage([name]);
        }
        return "That device is not reachable right now.";
    }

    private HashSet<Guid> OnlineDeviceSnapshot()
    {
        lock (_onlineDevices) return [.. _onlineDevices];
    }

    /// <summary>
    /// An unauthenticated mDNS <c>v &lt; 2</c> counts only for devices that have not proved v2 with a valid
    /// pong (<paramref name="verifiedOnlineIds"/>), so a LAN impostor cannot block a live device.
    /// </summary>
    public static bool DeviceNeedsUpdate(
        Guid deviceId,
        IEnumerable<Peer> mdnsPeers,
        IReadOnlySet<Guid> outdatedDeviceIds,
        IReadOnlySet<Guid>? verifiedOnlineIds = null) =>
        outdatedDeviceIds.Contains(deviceId)
        || (verifiedOnlineIds?.Contains(deviceId) != true
            && mdnsPeers.Any(peer => peer.Id == deviceId && peer.NeedsUpdate));

    public bool IsDeviceOnline(Guid deviceId)
    {
        lock (_onlineDevices) return _onlineDevices.Contains(deviceId);
    }

    public async Task RefreshDeviceLivenessAsync(CancellationToken cancellationToken = default)
    {
        if (_disposed || IsSyncPaused || !await _livenessRefreshLock.WaitAsync(0, cancellationToken)) return;
        try
        {
            var devices = PairedDevices.ToArray();
            var report = await DeviceLiveness.ResolveAsync(devices, VisiblePeers, PingDeviceAsync, cancellationToken);
            ApplyLiveness(report, devices, rebuildAll: true);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            _livenessRefreshLock.Release();
        }
    }

    public async Task SendFileAsync(string path, Guid deviceId)
    {
        try { await SendFileCoreAsync(path, deviceId); }
        catch (OperationCanceledException) { }
        catch (Exception exception) { LastError = $"File transfer failed: {exception.Message}"; }
    }

    public async Task SendFilesAsync(IEnumerable<string> paths, Guid deviceId)
    {
        var validPaths = paths.Where(File.Exists).ToArray();
        if (validPaths.Length == 0) throw new InvalidOperationException("No shared files are available to send.");
        try
        {
            foreach (var path in validPaths) await SendFileCoreAsync(path, deviceId);
        }
        catch (Exception exception)
        {
            LastError = $"File transfer failed: {exception.Message}";
            throw;
        }
    }

    private async Task SendFileCoreAsync(string path, Guid deviceId)
    {
        var reachable = await ReconnectDeviceAsync(deviceId, false);
        // Checked after the reconnect probe, which records the advertised version.
        if (DeviceNeedsUpdate(deviceId)) throw new PeerNeedsUpdateException();
        if (!reachable && DeviceClockSkewed(deviceId))
            throw new PeerClockOutOfSyncException(PairedDevices.First(item => item.Id == deviceId).Name);
        if (!reachable)
            throw new InvalidOperationException("The device is not currently reachable.");
        var device = PairedDevices.First(item => item.Id == deviceId);
        var peer = ResolveVerifiedPeer(device, IsDeviceOnline(deviceId), VisiblePeers, OutdatedDeviceSnapshot())
            ?? throw new InvalidOperationException("The device is not currently reachable.");
        var cancellation = new CancellationTokenSource();
        var transferId = Guid.NewGuid().ToString("D").ToLowerInvariant();
        _fileCancellations[transferId] = cancellation;
        var progress = new Progress<FileTransferProgress>(UpdateTransfer);
        try { await _fileSender.SendAsync(path, peer, progress, cancellation.Token, transferId); }
        finally { _fileCancellations.Remove(transferId); cancellation.Dispose(); }
    }

    public async Task HandleDroppedFilesAsync(string[] paths)
    {
        var validPaths = paths.Where(File.Exists).ToArray();
        if (validPaths.Length == 0) return;
        var targets = PairedDevices
            .Select(device => ResolveVerifiedPeer(device, IsDeviceOnline(device.Id), VisiblePeers))
            .OfType<Peer>()
            .ToArray();
        if (targets.Length == 0)
        {
            ReportError("Pair a reachable device before sending a file.");
            return;
        }
        if (targets.Length > 1)
        {
            ReportError("Choose Send file next to a device in Devices.");
            DevicesRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        foreach (var path in validPaths) await SendFileAsync(path, targets[0].Id);
    }

    public void CancelTransfer(string transferId)
    {
        if (_fileCancellations.Remove(transferId, out var cancellation)) cancellation.Cancel();
    }

    public byte[]? GetPairKey(Guid deviceId) => PairingCoordinator.PairedStore.GetKey(deviceId);
    public bool IsConnected(Guid deviceId) => PairingCoordinator.PairedStore.IsConnected(deviceId);

    public ReceiveResult Receive(ClipPayload payload)
    {
        if (IsSyncPaused) return new ReceiveResult(ReceiveStatus.Duplicate);
        return Application.Current.Dispatcher.Invoke(() =>
        {
            _lastWrittenHash = payload.Type switch
            {
                ClipType.Text when payload.Text is not null => ContentHasher.TextHash(payload.Text),
                ClipType.Image when payload.ImageBase64 is not null =>
                    ContentHasher.ImageHash(Convert.FromBase64String(payload.ImageBase64)),
                _ => payload.ContentHash,
            };
            var result = _receiver.Receive(payload);
            Refresh();
            return result;
        });
    }

    public Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        _fileReceiver.OfferAsync(offer, pairKey, sourceDeviceId, cancellationToken);
    public Task<FileReceiveResult> HandleFileChunkAsync(string transferId, int chunkIndex, byte[] body, CancellationToken cancellationToken) =>
        _fileReceiver.ChunkAsync(transferId, chunkIndex, body, cancellationToken);
    public Task<FileReceiveResult> HandleFileFinishAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        _fileReceiver.FinishAsync(transferId, sourceDeviceId, cancellationToken);
    public Task<FileReceiveResult> HandleFileCancelAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        _fileReceiver.CancelAsync(transferId, sourceDeviceId, cancellationToken);

    public Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken) =>
        PairingCoordinator.HandlePairStartAsync(request, remoteHost, cancellationToken);

    public Task<PairRevealOutcome> HandlePairRevealAsync(
        PairRevealRequest request,
        CancellationToken cancellationToken) =>
        PairingCoordinator.HandlePairRevealAsync(request, cancellationToken);

    public Task<PairConfirmOutcome> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken) =>
        PairingCoordinator.HandlePairConfirmAsync(request, cancellationToken);

    public static IReadOnlyList<Peer> ComposeSendTargets(
        IEnumerable<Peer> mdnsPeers,
        IEnumerable<PairedDevice> pairedDevices,
        IReadOnlySet<Guid>? outdatedDeviceIds = null,
        IReadOnlySet<Guid>? verifiedOnlineIds = null)
    {
        var devices = pairedDevices.ToArray();
        var peers = mdnsPeers.ToArray();
        // Paired devices go to their stored (ping-verified) host, never an mDNS-claimed one.
        // An older mDNS `v` keeps them from being sent to, unless a valid pong proved v2.
        var outdated = new HashSet<Guid>(outdatedDeviceIds ?? new HashSet<Guid>());
        outdated.UnionWith(peers
            .Where(peer => peer.NeedsUpdate && verifiedOnlineIds?.Contains(peer.Id) != true)
            .Select(peer => peer.Id));
        var byId = new Dictionary<Guid, Peer>();
        foreach (var device in devices)
        {
            if (!device.Connected) continue;
            if (!string.IsNullOrWhiteSpace(device.Host))
                byId[device.Id] = StoredHostPeer(device, device.Host!, outdated);
        }
        return byId.Values.ToArray();
    }

    public static IReadOnlyList<Peer> ComposeJoinCandidates(
        IEnumerable<Peer> mdnsPeers,
        IEnumerable<Peer> sweptPeers) =>
        mdnsPeers.Concat(sweptPeers).DistinctBy(peer => peer.Id).ToArray();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _clipboard.Changed -= ClipboardChanged;
        _clipboardDebounce?.Cancel();
        _clipboardDebounce?.Dispose();
        _lifetime.Cancel();
        _livenessTimer.Dispose();
        _mdns.Dispose();
        _fileReceiver.Dispose();
    }

    private void ClipboardChanged(object? sender, EventArgs args)
    {
        _clipboardDebounce?.Cancel();
        _clipboardDebounce?.Dispose();
        var cancellation = new CancellationTokenSource();
        _clipboardDebounce = cancellation;
        _ = DebounceClipboardAsync(cancellation.Token);
    }

    private async Task DebounceClipboardAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(300), cancellationToken);
            // The debounce token only covers the wait above. Windows often raises a second clipboard
            // update for one copy; that must not cancel the send the first one started, because the
            // second read is then suppressed as a duplicate and the clip would never be sent.
            await await Application.Current.Dispatcher.InvokeAsync(() => ProcessClipboardChangeAsync(_lifetime.Token));
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task ProcessClipboardChangeAsync(CancellationToken cancellationToken)
    {
        if (IsSyncPaused) return;
        ClipboardSnapshot snapshot;
        try
        {
            snapshot = _clipboard.ReadSnapshot();
        }
        catch (Exception exception)
        {
            LastError = $"Clipboard read failed: {exception.Message}";
            return;
        }

        string hash;
        ClipItem clip;
        if (snapshot.ImageData is { Length: > 0 } image)
        {
            hash = ContentHasher.ImageHash(image);
            if (ShouldSuppress(hash)) return;
            clip = Store.AddImageData(image, "png");
        }
        else if (!string.IsNullOrEmpty(snapshot.Text))
        {
            hash = ContentHasher.TextHash(snapshot.Text);
            if (ShouldSuppress(hash)) return;
            clip = Store.AddText(snapshot.Text);
        }
        else
        {
            return;
        }

        Refresh();
        if (_lastBroadcastClipId == clip.Id) return;
        _lastBroadcastClipId = clip.Id;
        try
        {
            var result = await _sender.BroadcastAsync(
                clip,
                ComposeSendTargets(VisiblePeers, PairedDevices, OutdatedDeviceSnapshot(), OnlineDeviceSnapshot()),
                cancellationToken);
            SyncLog.Write(_settings.StorageDirectory,
                $"clip {clip.Type} sent: targets={result.PairedPeerCount} ok={result.SuccessCount} failed={result.FailureCount}"
                + string.Concat(result.Failures.Select(failure => $" [{failure.PeerName}: {failure.Reason}]")));
            if (result.NeedsUpdateCount > 0) LastError = WireProtocol.UpdateOtherDeviceMessage;
            else if (result.ClockOutOfSyncPeerNames.Count > 0)
                LastError = WireProtocol.ClockOutOfSyncMessage(result.ClockOutOfSyncPeerNames);
            else if (UnexpectedSendFailureMessage(result.Failures, OnlineDeviceSnapshot()) is { } failureMessage)
                LastError = failureMessage;
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            SyncLog.Write(_settings.StorageDirectory, $"clip {clip.Type} send error: {exception.Message}");
            LastError = exception.Message;
        }
    }

    /// <summary>
    /// A failed send is worth a banner only for a device that just answered a ping: a device that is
    /// simply off or asleep fails every copy and must not nag.
    /// </summary>
    public static string? UnexpectedSendFailureMessage(
        IReadOnlyList<ClipSendFailure> failures,
        IReadOnlySet<Guid> onlineDeviceIds)
    {
        var names = failures
            .Where(failure => onlineDeviceIds.Contains(failure.PeerId))
            .Select(failure => failure.PeerName)
            .ToArray();
        return names.Length == 0 ? null : $"The last copy did not reach {string.Join(", ", names)}.";
    }

    private bool ShouldSuppress(string hash) =>
        hash == _lastWrittenHash || hash == Store.Items.FirstOrDefault()?.ContentHash;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    /// <summary>
    /// Receiver events arrive on server threads, which are still answering the transfer's request:
    /// nothing here may block them, so work is queued to the UI thread and dialogs open later.
    /// </summary>
    private void UpdateTransfer(FileTransferProgress progress)
    {
        void Apply()
        {
            var index = _transfers.FindIndex(item => item.TransferId == progress.TransferId);
            // A late progress event must not reopen a finished row.
            if (index >= 0 && progress.Status == FileTransferStatus.Active && _transfers[index].Status != FileTransferStatus.Active) return;
            if (index >= 0) _transfers[index] = progress; else _transfers.Insert(0, progress);
            // Newest first; keep only the most recent MaxTransfers rows.
            if (_transfers.Count > MaxTransfers) _transfers.RemoveRange(MaxTransfers, _transfers.Count - MaxTransfers);
            OnPropertyChanged(nameof(Transfers)); StateChanged?.Invoke(this, EventArgs.Empty);
            // Modal dialogs run after this returns, never inside the caller's stack.
            if (progress.Direction == FileTransferDirection.Receiving && progress.Status == FileTransferStatus.Completed)
                Application.Current.Dispatcher.BeginInvoke(() => ProcessCompletedReceive(progress));
        }
        if (Application.Current.Dispatcher.CheckAccess()) Apply(); else Application.Current.Dispatcher.BeginInvoke(Apply);
    }

    private void ProcessCompletedReceive(FileTransferProgress progress)
    {
        var mode = _settings.Current.ReceiveDestinationMode;
        if (mode == ReceiveDestinationMode.Unset)
        {
            var choice = MessageBox.Show(
                "Where should ClipboardSS save received files?\n\nYes: keep using Downloads\nNo: choose a folder\nCancel: ask every time",
                "Received files", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (choice == MessageBoxResult.Yes)
                _settings.Update(current => current with { ReceiveDestinationMode = ReceiveDestinationMode.Default, ReceiveDestinationPath = null });
            else if (choice == MessageBoxResult.No)
                ChooseReceiveFolder();
            else
                _settings.Update(current => current with { ReceiveDestinationMode = ReceiveDestinationMode.Ask, ReceiveDestinationPath = null });
        }

        if (_settings.Current.ReceiveDestinationMode == ReceiveDestinationMode.Ask)
            MoveReceivedFileAfterPrompt(progress);

        var finalProgress = _transfers.FirstOrDefault(item => item.TransferId == progress.TransferId) ?? progress;
        if (_notifiedReceiveIds.Add(progress.TransferId) && !string.IsNullOrWhiteSpace(finalProgress.SavedPath))
            _receivedFileNotifications.ShowReceivedFile(finalProgress.SavedPath);
    }

    private void ChooseReceiveFolder()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Choose received files folder" };
        if (dialog.ShowDialog(Application.Current.MainWindow) == true)
            _settings.Update(current => current with { ReceiveDestinationMode = ReceiveDestinationMode.Folder, ReceiveDestinationPath = dialog.FolderName });
    }

    private void MoveReceivedFileAfterPrompt(FileTransferProgress progress)
    {
        if (string.IsNullOrWhiteSpace(progress.SavedPath) || !File.Exists(progress.SavedPath)) return;
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Save received file to" };
        if (dialog.ShowDialog(Application.Current.MainWindow) != true) return;
        try
        {
            var destination = CollisionSafePath(dialog.FolderName, Path.GetFileName(progress.SavedPath));
            File.Move(progress.SavedPath, destination);
            var index = _transfers.FindIndex(item => item.TransferId == progress.TransferId);
            if (index >= 0) _transfers[index] = progress with { SavedPath = destination };
            OnPropertyChanged(nameof(Transfers)); StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception)
        {
            LastError = $"Could not move received file: {exception.Message}";
        }
    }

    private static string CollisionSafePath(string directory, string name)
    {
        var path = Path.Combine(directory, name);
        for (var number = 2; File.Exists(path); number++)
            path = Path.Combine(directory, $"{Path.GetFileNameWithoutExtension(name)} ({number}){Path.GetExtension(name)}");
        return path;
    }
}

public enum PasteMode
{
    KeepWindowOpen,
    CloseWindow,
}

public sealed record PasteRequest(ClipItem Clip, PasteMode Mode);
