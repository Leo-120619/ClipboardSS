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
    public void PairedDeviceStorePersistsOptionalHostAndLegacyRecord()
    {
        using var directory = new TemporaryDirectory();
        var path = System.IO.Path.Combine(directory.Path, "paired-devices.json");
        var legacyId = Guid.NewGuid();
        File.WriteAllText(path, $"[{{\"id\":\"{legacyId:D}\",\"name\":\"Old\"}}]");
        var keys = new InMemoryPairKeyStorage();
        var store = new PairedDeviceStore(path, keys);

        Assert.Null(store.Devices[0].Host);
        var device = new PairedDevice(Guid.NewGuid(), "Mac", "192.168.0.4");
        store.AddDevice(device, Enumerable.Repeat((byte)7, 32).ToArray());

        var reopened = new PairedDeviceStore(path, keys);
        Assert.Contains(reopened.Devices, item => item.Host == "192.168.0.4");
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
