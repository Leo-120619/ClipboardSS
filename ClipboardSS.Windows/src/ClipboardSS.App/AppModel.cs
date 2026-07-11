using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using ClipboardSS.App.Net;
using ClipboardSS.App.Pairing;
using ClipboardSS.App.Settings;
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
    private readonly Dictionary<string, CancellationTokenSource> _fileCancellations = [];
    private readonly List<FileTransferProgress> _transfers = [];
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
        SubnetSweeper sweeper,
        FileSender fileSender,
        FileReceiver fileReceiver,
        SettingsStore settings)
    {
        Store = store;
        PairingCoordinator = pairingCoordinator;
        _clipboard = clipboard;
        _writer = new ClipboardWriter(clipboard, store);
        _receiver = new ClipReceiver(store, clipboard);
        _sender = sender;
        _mdns = mdns;
        _sweeper = sweeper;
        _fileSender = fileSender;
        _fileReceiver = fileReceiver;
        _settings = settings;
        _fileReceiver.TransferChanged += UpdateTransfer;
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

    public void SetConnected(Guid deviceId, bool connected)
    {
        PairingCoordinator.PairedStore.SetConnected(deviceId, connected);
        OnPropertyChanged(nameof(PairedDevices));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool IsDeviceConnected(Guid deviceId) => PairingCoordinator.PairedStore.IsConnected(deviceId);

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
        var peer = ComposeSendTargets(VisiblePeers, PairedDevices).FirstOrDefault(item => item.Id == deviceId)
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
        var targets = ComposeSendTargets(VisiblePeers, PairedDevices);
        if (targets.Count == 0)
        {
            ReportError("Pair a reachable device before sending a file.");
            return;
        }
        if (targets.Count > 1)
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

    public Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, CancellationToken cancellationToken) =>
        _fileReceiver.OfferAsync(offer, pairKey, cancellationToken);
    public Task<FileReceiveResult> HandleFileChunkAsync(string transferId, int chunkIndex, byte[] body, CancellationToken cancellationToken) =>
        _fileReceiver.ChunkAsync(transferId, chunkIndex, body, cancellationToken);
    public Task<FileReceiveResult> HandleFileFinishAsync(string transferId, CancellationToken cancellationToken) =>
        _fileReceiver.FinishAsync(transferId, cancellationToken);
    public Task<FileReceiveResult> HandleFileCancelAsync(string transferId, CancellationToken cancellationToken) =>
        _fileReceiver.CancelAsync(transferId, cancellationToken);

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
        var devices = pairedDevices.ToArray();
        var byId = new Dictionary<Guid, Peer>();
        foreach (var device in devices)
        {
            if (!device.Connected) continue;
            if (!string.IsNullOrWhiteSpace(device.Host))
                byId[device.Id] = new Peer(device.Id, device.Name, device.Host, 51888);
        }
        var connectedIds = devices.Where(device => device.Connected).Select(device => device.Id).ToHashSet();
        foreach (var peer in mdnsPeers)
            if (connectedIds.Contains(peer.Id)) byId[peer.Id] = peer;
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

    private void UpdateTransfer(FileTransferProgress progress)
    {
        void Apply()
        {
            var index = _transfers.FindIndex(item => item.TransferId == progress.TransferId);
            if (index >= 0) _transfers[index] = progress; else _transfers.Insert(0, progress);
            OnPropertyChanged(nameof(Transfers)); StateChanged?.Invoke(this, EventArgs.Empty);
            if (progress.Direction == FileTransferDirection.Receiving && progress.Status == FileTransferStatus.Completed)
                ProcessCompletedReceive(progress);
        }
        if (Application.Current.Dispatcher.CheckAccess()) Apply(); else Application.Current.Dispatcher.Invoke(Apply);
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
