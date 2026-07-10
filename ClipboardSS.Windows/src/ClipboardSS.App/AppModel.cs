using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using ClipboardSS.App.Net;
using ClipboardSS.App.Pairing;
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
    private readonly MdnsService _mdns;
    private readonly SubnetSweeper _sweeper;
    private CancellationTokenSource? _clipboardDebounce;
    private string? _lastWrittenHash;
    private Guid? _lastBroadcastClipId;
    private string? _lastError;
    private bool _isSyncPaused;
    private bool _disposed;

    public AppModel(
        ClipStore store,
        ClipboardInterop clipboard,
        PairingCoordinator pairingCoordinator,
        ClipSender sender,
        MdnsService mdns,
        SubnetSweeper sweeper)
    {
        Store = store;
        PairingCoordinator = pairingCoordinator;
        _clipboard = clipboard;
        _writer = new ClipboardWriter(clipboard, store);
        _receiver = new ClipReceiver(store, clipboard);
        _sender = sender;
        _mdns = mdns;
        _sweeper = sweeper;
        _clipboard.Changed += ClipboardChanged;
        _mdns.PeersChanged += (_, _) => OnPropertyChanged(nameof(VisiblePeers));
        PairingCoordinator.PairedDevicesChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PairedDevices));
            StateChanged?.Invoke(this, EventArgs.Empty);
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? StateChanged;
    public event Action<PasteRequest>? PasteRequested;
    public ClipStore Store { get; }
    public PairingCoordinator PairingCoordinator { get; }
    public IReadOnlyList<ClipItem> Clips => Store.Items;
    public IReadOnlyList<Peer> VisiblePeers => _mdns.Peers;
    public IReadOnlyList<PairedDevice> PairedDevices => PairingCoordinator.PairedStore.Devices;

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
            OnPropertyChanged();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Start()
    {
        _ = _mdns.Start();
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

    public async Task<bool> JoinWithCodeAsync(string code, CancellationToken cancellationToken = default)
    {
        if (code.Length != 6 || code.Any(character => !char.IsAsciiDigit(character)))
        {
            LastError = "Enter a 6-digit pairing code.";
            return false;
        }

        LastError = null;
        var mdnsPeers = VisiblePeers;
        if (await TryPairingAsync(mdnsPeers, code, cancellationToken)) return true;
        var sweptPeers = await _sweeper.SweepAsync(cancellationToken);
        if (await TryPairingAsync(ComposeJoinCandidates(mdnsPeers, sweptPeers), code, cancellationToken))
            return true;
        LastError = "No device accepted that code. Make sure the other device is showing a code on the same Wi-Fi.";
        return false;
    }

    public void Unpair(Guid deviceId)
    {
        PairingCoordinator.PairedStore.RemoveDevice(deviceId);
        OnPropertyChanged(nameof(PairedDevices));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public byte[]? GetPairKey(Guid deviceId) => PairingCoordinator.PairedStore.GetKey(deviceId);

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

    public Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken) =>
        PairingCoordinator.HandlePairStartAsync(request, remoteHost, cancellationToken);

    public Task<bool> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken) =>
        PairingCoordinator.HandlePairConfirmAsync(request, cancellationToken);

    public static IReadOnlyList<Peer> ComposeSendTargets(
        IEnumerable<Peer> mdnsPeers,
        IEnumerable<PairedDevice> pairedDevices)
    {
        var byId = new Dictionary<Guid, Peer>();
        foreach (var device in pairedDevices)
        {
            if (!string.IsNullOrWhiteSpace(device.Host))
                byId[device.Id] = new Peer(device.Id, device.Name, device.Host, 51888);
        }
        foreach (var peer in mdnsPeers) byId[peer.Id] = peer;
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
        _mdns.Dispose();
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
            await await Application.Current.Dispatcher.InvokeAsync(() => ProcessClipboardChangeAsync(cancellationToken));
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
            await _sender.BroadcastAsync(
                clip,
                ComposeSendTargets(VisiblePeers, PairedDevices),
                cancellationToken);
        }
        catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
        {
            LastError = exception.Message;
        }
    }

    private bool ShouldSuppress(string hash) =>
        hash == _lastWrittenHash || hash == Store.Items.FirstOrDefault()?.ContentHash;

    private async Task<bool> TryPairingAsync(
        IEnumerable<Peer> candidates,
        string code,
        CancellationToken cancellationToken)
    {
        foreach (var peer in candidates)
        {
            try
            {
                await PairingCoordinator.StartPairingAsync(peer, code, cancellationToken);
                OnPropertyChanged(nameof(PairedDevices));
                StateChanged?.Invoke(this, EventArgs.Empty);
                return true;
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
            }
        }
        return false;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public enum PasteMode
{
    KeepWindowOpen,
    CloseWindow,
}

public sealed record PasteRequest(ClipItem Clip, PasteMode Mode);
