using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using System.Text;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

public sealed class SyncCoreTests
{
    [Fact]
    public void ClipboardMonitorDebouncesChangeCountAndPrefersImages()
    {
        using var directory = new TemporaryDirectory();
        var pasteboard = new FakePasteboard
        {
            ChangeCount = 1,
            Snapshot = new ClipboardSnapshot("text", [1, 2, 3]),
        };
        var store = new ClipStore(directory.Path);
        var monitor = new ClipboardMonitor(pasteboard, store);

        monitor.Poll();
        monitor.Poll();

        Assert.Single(store.Items);
        Assert.Equal(ClipType.Image, store.Items[0].Type);

        pasteboard.ChangeCount = 2;
        pasteboard.Snapshot = new ClipboardSnapshot("two", null);
        monitor.Poll();
        Assert.Equal([ClipType.Text, ClipType.Image], store.Items.Select(item => item.Type));
    }

    [Fact]
    public void ClipboardWriterCopiesDataMarksMruAndReportsMissingImage()
    {
        using var directory = new TemporaryDirectory();
        var store = new ClipStore(directory.Path);
        var text = store.AddText("hello");
        var image = store.AddImageData([1, 2, 3], "png");
        var pasteboard = new FakePasteboard();
        var writer = new ClipboardWriter(pasteboard, store);

        writer.Copy(text);
        Assert.Equal("hello", pasteboard.LastText);
        Assert.Equal(text.Id, store.Items[0].Id);
        Assert.NotNull(store.Items[0].LastCopiedAt);

        File.Delete(image.ResolveImagePath(directory.Path));
        Assert.Throws<ClipboardWriterException>(() => writer.Copy(image));
    }

    [Fact]
    public void ReceiverWritesClipboardAndReportsContentDuplicate()
    {
        using var directory = new TemporaryDirectory();
        var store = new ClipStore(directory.Path);
        var pasteboard = new FakePasteboard();
        var receiver = new ClipReceiver(store, pasteboard);
        var payload = TextPayload("hello net");

        var first = receiver.Receive(payload);
        var second = receiver.Receive(payload with { Id = Guid.NewGuid() });

        Assert.Equal(ReceiveStatus.Added, first.Status);
        Assert.Equal(ReceiveStatus.Duplicate, second.Status);
        Assert.Single(store.Items);
        Assert.Equal("hello net", pasteboard.LastText);
    }

    [Fact]
    public void Receive_UndecodableImage_IsRejectedAndNotStored()
    {
        using var directory = new TemporaryDirectory();
        var store = new ClipStore(directory.Path);
        var pasteboard = new FakePasteboard();
        var receiver = new ClipReceiver(store, pasteboard);
        var garbage = new byte[32];
        new Random(20261110).NextBytes(garbage);
        byte[] imageData = [0x89, 0x50, 0x4e, 0x47, .. garbage];
        var payload = new ClipPayload
        {
            Id = Guid.NewGuid(),
            Type = ClipType.Image,
            CreatedAt = DateTimeOffset.UtcNow,
            ImageBase64 = Convert.ToBase64String(imageData),
            ImageExtension = "png",
            PreviewText = "Image",
            ContentHash = "ignored-by-receiver",
            SourceDeviceName = "Phone",
        };

        Assert.Throws<InvalidDataException>(() => receiver.Receive(payload));

        Assert.Empty(store.Items);
        Assert.Empty(Directory.GetFiles(System.IO.Path.Combine(directory.Path, "Images")));
        Assert.Equal(0, pasteboard.ClearCount);
        Assert.Null(pasteboard.LastImageData);
    }

    [Fact]
    public void Receive_ValidPngImage_IsStoredAndWrittenToPasteboard()
    {
        using var directory = new TemporaryDirectory();
        var store = new ClipStore(directory.Path);
        var pasteboard = new FakePasteboard();
        var receiver = new ClipReceiver(store, pasteboard);
        var payload = new ClipPayload
        {
            Id = Guid.NewGuid(),
            Type = ClipType.Image,
            CreatedAt = DateTimeOffset.UtcNow,
            ImageBase64 = Convert.ToBase64String(OnePixelPng),
            ImageExtension = "PNG",
            PreviewText = "Image",
            ContentHash = "ignored-by-receiver",
            SourceDeviceName = "Phone",
        };

        var result = receiver.Receive(payload);

        Assert.Equal(ReceiveStatus.Added, result.Status);
        Assert.EndsWith(".png", store.Items[0].ImagePath);
        Assert.Equal(OnePixelPng, pasteboard.LastImageData);
    }

    [Theory]
    [InlineData(new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10 })]
    [InlineData(new byte[] { 0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0 })]
    [InlineData(new byte[] { 0x42, 0x4D, 0, 0, 0, 0 })]
    [InlineData(new byte[] { 0x49, 0x49, 0x2A, 0x00, 8, 0 })]
    [InlineData(new byte[] { 0x4D, 0x4D, 0x00, 0x2A, 0, 8 })]
    [InlineData(new byte[] { 0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50 })]
    public void MagicNumberImageValidator_AcceptsKnownSignatures(byte[] data)
    {
        Assert.True(new MagicNumberImageValidator().IsValidImage(data));
    }

    [Theory]
    [InlineData(new byte[] { })]
    [InlineData(new byte[] { 0x89, 0x50, 0x4E, 0x47 })]
    [InlineData(new byte[] { 0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45 })]
    [InlineData(new byte[] { 0x4D, 0x5A, 0x90, 0x00 })]
    public void MagicNumberImageValidator_RejectsUnknownOrTruncatedData(byte[] data)
    {
        Assert.False(new MagicNumberImageValidator().IsValidImage(data));
    }

    [Fact]
    public void PairedDeviceStorePersistsOptionalHostAndLegacyRecord()
    {
        using var directory = new TemporaryDirectory();
        var path = System.IO.Path.Combine(directory.Path, "paired-devices.json");
        var legacyId = Guid.NewGuid();
        File.WriteAllText(path, $"[{{\"id\":\"{legacyId:D}\",\"name\":\"Old\"}}]");
        var keys = new InMemoryPairKeyStorage();
        var store = new PairedDeviceStore(path, keys);

        Assert.Null(store.Devices[0].Host);
        Assert.True(store.Devices[0].Connected);
        var device = new PairedDevice(Guid.NewGuid(), "Mac", "192.168.0.4");
        store.AddDevice(device, Enumerable.Repeat((byte)7, 32).ToArray());
        store.SetConnected(device.Id, false);
        store.AddDevice(device with { Name = "Mac renamed" }, Enumerable.Repeat((byte)8, 32).ToArray());
        store.UpdateHost(device.Id, "192.168.0.42");

        var reopened = new PairedDeviceStore(path, keys);
        Assert.Contains(reopened.Devices, item => item.Host == "192.168.0.42");
        Assert.False(reopened.IsConnected(device.Id));
        Assert.Equal("Mac renamed", reopened.Devices.Single(item => item.Id == device.Id).Name);
    }

    [Fact]
    public async Task SenderFiltersSelfAndUnpairedPeersAndChecksHttpStatus()
    {
        using var directory = new TemporaryDirectory();
        var myId = Guid.NewGuid();
        var pairedId = Guid.NewGuid();
        var unpairedId = Guid.NewGuid();
        var pairedStore = new PairedDeviceStore(
            System.IO.Path.Combine(directory.Path, "paired.json"),
            new InMemoryPairKeyStorage());
        pairedStore.AddDevice(
            new PairedDevice(pairedId, "Phone"),
            Enumerable.Repeat((byte)9, 32).ToArray());
        var transport = new FakePeerTransport();
        var sender = new ClipSender(
            new DeviceIdentity(myId, "Windows"),
            pairedStore,
            transport,
            directory.Path);
        var clip = new ClipStore(directory.Path).AddText("broadcast");

        var result = await sender.BroadcastAsync(clip, [
            new Peer(myId, "Self", "10.0.0.2", 51888),
            new Peer(pairedId, "Phone", "10.0.0.3", 51888),
            new Peer(unpairedId, "Other", "10.0.0.4", 51888),
        ], TestContext.Current.CancellationToken);

        Assert.Equal(new ClipSendResult(2, 1, 1, 0), result);
        Assert.Single(transport.Requests);
        Assert.Equal("/v1/clip", HttpCodec.ParseRequest(transport.Requests[0].Data).Path);

        transport.Response = HttpCodec.EncodeResponse(new HttpResponse(401, new Dictionary<string, string>(), []));
        result = await sender.BroadcastAsync(
            clip,
            [new Peer(pairedId, "Phone", "10.0.0.3", 51888)],
            TestContext.Current.CancellationToken);
        Assert.Equal(1, result.FailureCount);
        Assert.Equal(0, result.SuccessCount);
    }

    [Fact]
    public async Task SenderSealsForRecipientAndSkipsPeersThatNeedAnUpdate()
    {
        using var directory = new TemporaryDirectory();
        var myId = Guid.NewGuid();
        var currentId = Guid.NewGuid();
        var outdatedId = Guid.NewGuid();
        var key = Enumerable.Repeat((byte)9, 32).ToArray();
        var pairedStore = new PairedDeviceStore(
            System.IO.Path.Combine(directory.Path, "paired.json"),
            new InMemoryPairKeyStorage());
        pairedStore.AddDevice(new PairedDevice(currentId, "Phone"), key);
        pairedStore.AddDevice(new PairedDevice(outdatedId, "Old"), key);
        var transport = new FakePeerTransport();
        var sender = new ClipSender(new DeviceIdentity(myId, "Windows"), pairedStore, transport, directory.Path);
        var clip = new ClipStore(directory.Path).AddText("hi");

        var result = await sender.BroadcastAsync(clip, [
            new Peer(currentId, "Phone", "10.0.0.3", 51888),
            new Peer(outdatedId, "Old", "10.0.0.4", 51888, ProtocolVersion: 1),
        ], TestContext.Current.CancellationToken);

        Assert.Equal(1, result.SuccessCount);
        Assert.Equal(1, result.NeedsUpdateCount);
        var request = HttpCodec.ParseRequest(Assert.Single(transport.Requests).Data);
        var envelope = JsonSerializer.Deserialize<ClipEnvelope>(request.Body, WireJson.Options)!;
        Assert.Equal(2, envelope.V);
        Assert.Equal("hi", EnvelopeCrypto.Open(envelope, EnvelopePurpose.Clip, currentId, key).Text);

        transport.Response = HttpCodec.EncodeResponse(new HttpResponse(426, new Dictionary<string, string>(), []));
        result = await sender.BroadcastAsync(
            clip, [new Peer(currentId, "Phone", "10.0.0.3", 51888)], TestContext.Current.CancellationToken);
        Assert.Equal(1, result.FailureCount);
        Assert.Equal(1, result.NeedsUpdateCount);
    }

    [Fact]
    public async Task FileSenderRefusesOutdatedPeersAndMaps426ToNeedsUpdate()
    {
        using var directory = new TemporaryDirectory();
        var peerId = Guid.NewGuid();
        var pairedStore = new PairedDeviceStore(
            System.IO.Path.Combine(directory.Path, "paired.json"),
            new InMemoryPairKeyStorage());
        pairedStore.AddDevice(new PairedDevice(peerId, "Phone"), Enumerable.Repeat((byte)9, 32).ToArray());
        var file = System.IO.Path.Combine(directory.Path, "payload.bin");
        await File.WriteAllBytesAsync(file, [1, 2, 3], TestContext.Current.CancellationToken);
        var transport = new FakePeerTransport();
        var sender = new FileSender(new DeviceIdentity(Guid.NewGuid(), "Windows"), pairedStore, transport);

        var outdated = await Assert.ThrowsAsync<PeerNeedsUpdateException>(() => sender.SendAsync(
            file, new Peer(peerId, "Phone", "10.0.0.3", 51888, ProtocolVersion: 1),
            cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(WireProtocol.UpdateOtherDeviceMessage, outdated.Message);
        Assert.Empty(transport.Requests);

        transport.Response = HttpCodec.EncodeResponse(new HttpResponse(426, new Dictionary<string, string>(), []));
        await Assert.ThrowsAsync<PeerNeedsUpdateException>(() => sender.SendAsync(
            file, new Peer(peerId, "Phone", "10.0.0.3", 51888),
            cancellationToken: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task SendersReportStaleAnswersAsClockOutOfSyncWithThatDevice()
    {
        using var directory = new TemporaryDirectory();
        var peerId = Guid.NewGuid();
        var pairedStore = new PairedDeviceStore(
            System.IO.Path.Combine(directory.Path, "paired.json"),
            new InMemoryPairKeyStorage());
        pairedStore.AddDevice(new PairedDevice(peerId, "Phone"), Enumerable.Repeat((byte)9, 32).ToArray());
        var transport = new FakePeerTransport
        {
            Response = HttpCodec.EncodeResponse(new HttpResponse(400,
                new Dictionary<string, string> { ["Content-Type"] = "application/json" },
                Encoding.UTF8.GetBytes("{\"status\":\"stale\"}"))),
        };
        var peer = new Peer(peerId, "Phone", "10.0.0.3", 51888);

        var clipSender = new ClipSender(new DeviceIdentity(Guid.NewGuid(), "Windows"), pairedStore, transport, directory.Path);
        var clip = new ClipStore(directory.Path).AddText("hi");
        var result = await clipSender.BroadcastAsync(clip, [peer], TestContext.Current.CancellationToken);
        Assert.Equal(1, result.FailureCount);
        Assert.Equal(0, result.NeedsUpdateCount);
        Assert.Equal(["Phone"], result.ClockOutOfSyncPeerNames);
        Assert.Equal("Clock out of sync with Phone.", WireProtocol.ClockOutOfSyncMessage(result.ClockOutOfSyncPeerNames));

        var file = System.IO.Path.Combine(directory.Path, "payload.bin");
        await File.WriteAllBytesAsync(file, [1, 2, 3], TestContext.Current.CancellationToken);
        var fileSender = new FileSender(new DeviceIdentity(Guid.NewGuid(), "Windows"), pairedStore, transport);
        var error = await Assert.ThrowsAsync<PeerClockOutOfSyncException>(() => fileSender.SendAsync(
            file, peer, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal("Phone", error.DeviceName);
        Assert.Equal("Clock out of sync with Phone.", error.Message);
    }

    private static readonly byte[] OnePixelPng = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==");

    private static ClipPayload TextPayload(string text) => new()
    {
        Id = Guid.NewGuid(),
        Type = ClipType.Text,
        CreatedAt = DateTimeOffset.UtcNow,
        Text = text,
        PreviewText = text,
        ContentHash = "ignored-by-receiver",
        SourceDeviceName = "Phone",
    };

    private sealed class FakePasteboard : IPasteboardClient
    {
        public long ChangeCount { get; set; }
        public ClipboardSnapshot Snapshot { get; set; } = new(null, null);
        public int ClearCount { get; private set; }
        public string? LastText { get; private set; }
        public byte[]? LastImageData { get; private set; }
        public long CurrentChangeCount() => ChangeCount;
        public ClipboardSnapshot ReadSnapshot() => Snapshot;

        public void ClearContents()
        {
            ClearCount++;
            LastText = null;
            LastImageData = null;
        }

        public void WriteText(string text) => LastText = text;
        public void WriteImageData(ReadOnlySpan<byte> data) => LastImageData = data.ToArray();
    }

    private sealed class InMemoryPairKeyStorage : IPairKeyStorage
    {
        private readonly Dictionary<Guid, byte[]> _keys = [];
        public void StoreKey(ReadOnlySpan<byte> key, Guid deviceId) => _keys[deviceId] = key.ToArray();
        public byte[]? GetKey(Guid deviceId) => _keys.GetValueOrDefault(deviceId)?.ToArray();
        public void DeleteKey(Guid deviceId) => _keys.Remove(deviceId);
    }

    private sealed class FakePeerTransport : IPeerTransport
    {
        public List<(byte[] Data, Peer Peer)> Requests { get; } = [];
        public byte[] Response { get; set; } = HttpCodec.EncodeResponse(
            new HttpResponse(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("OK")));

        public Task<byte[]> SendAsync(
            byte[] data,
            Peer peer,
            CancellationToken cancellationToken = default)
        {
            Requests.Add((data, peer));
            return Task.FromResult(Response);
        }
    }
}
