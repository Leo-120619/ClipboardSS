using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;
#pragma warning disable xUnit1051

namespace ClipboardSS.Core.Tests;

public sealed class FileTransferTests
{
    private static readonly Guid Peer = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Other = Guid.Parse("33333333-3333-3333-3333-333333333333");
    private static readonly byte[] PairKey = new byte[32];

    [Fact]
    public void OfferUsesCanonicalJsonFieldNamesAndStringTransferId()
    {
        var offer = Offer("abcdef", 3, ContentHasherFor([1, 2, 3]));
        var json = JsonSerializer.Serialize(offer, WireJson.Options);
        Assert.Equal("{\"transferId\":\"abcdef\",\"fileName\":\"test.bin\",\"fileSize\":3,\"mimeType\":\"application/octet-stream\",\"fileHash\":\"53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe\",\"chunkSize\":4194304,\"chunkCount\":1,\"createdAt\":\"2023-11-14T22:13:20Z\",\"sourceDeviceName\":\"Mac\"}", json);
    }

    [Fact]
    public async Task ReceiverHandlesLifecycleDuplicatesCancelAndHashMismatch()
    {
        using var temp = new TemporaryDirectory();
        var downloads = Path.Combine(temp.Path, "downloads");
        using var receiver = new FileReceiver(Path.Combine(temp.Path, "parts"), () => downloads);
        var pairKey = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var bytes = new byte[] { 1, 2, 3 };
        var offer = Offer("abcdef", bytes.Length, ContentHasherFor(bytes));
        Assert.Equal(200, (await receiver.OfferAsync(offer, pairKey, Peer)).StatusCode);
        Assert.Equal(409, (await receiver.FinishAsync("abcdef", Peer)).StatusCode);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "abcdef");
        var body = FileTransferCrypto.SealChunk(key, 0, bytes);
        Assert.Equal(1, (await receiver.ChunkAsync("abcdef", 0, body)).Received);
        Assert.Equal(1, (await receiver.ChunkAsync("abcdef", 0, body)).Received);
        var finished = await receiver.FinishAsync("abcdef", Peer);
        Assert.Equal(200, finished.StatusCode);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(finished.SavedPath!));

        var bad = Offer("bad", bytes.Length, new string('0', 64));
        await receiver.OfferAsync(bad, pairKey, Peer);
        await receiver.ChunkAsync("bad", 0, FileTransferCrypto.SealChunk(FileTransferCrypto.DeriveFileKey(pairKey, "bad"), 0, bytes));
        Assert.Equal(422, (await receiver.FinishAsync("bad", Peer)).StatusCode);
        Assert.Empty(Directory.GetFiles(Path.Combine(temp.Path, "parts")));

        await receiver.OfferAsync(Offer("cancel", bytes.Length, ContentHasherFor(bytes)), pairKey, Peer);
        Assert.Equal(200, (await receiver.CancelAsync("cancel", Peer)).StatusCode);
        Assert.Equal(410, (await receiver.ChunkAsync("cancel", 0, [])).StatusCode);
        Assert.Equal(200, (await receiver.CancelAsync("cancel", Peer)).StatusCode);
    }

    [Fact]
    public async Task ReceiverAcceptsOutOfOrderChunksAndGarbageCollectsIdleSessions()
    {
        using var temp = new TemporaryDirectory();
        var now = DateTimeOffset.UtcNow;
        using var receiver = new FileReceiver(Path.Combine(temp.Path, "parts"), () => Path.Combine(temp.Path, "downloads"), () => now);
        var pairKey = new byte[32];
        var bytes = new byte[FileTransferConstants.ChunkSize + 3]; new byte[] { 1, 2, 3 }.CopyTo(bytes, bytes.Length - 3);
        await receiver.OfferAsync(Offer("order", bytes.Length, ContentHasherFor(bytes)), pairKey, Peer);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "order");
        Assert.Equal(200, (await receiver.ChunkAsync("order", 1, FileTransferCrypto.SealChunk(key, 1, bytes[^3..]))).StatusCode);
        Assert.Equal(200, (await receiver.ChunkAsync("order", 0, FileTransferCrypto.SealChunk(key, 0, bytes.AsSpan(0, FileTransferConstants.ChunkSize)))).StatusCode);
        Assert.Equal(200, (await receiver.FinishAsync("order", Peer)).StatusCode);
        await receiver.OfferAsync(Offer("idle", 3, ContentHasherFor([1, 2, 3])), pairKey, Peer);
        now += TimeSpan.FromSeconds(61); await receiver.CleanupExpiredAsync();
        Assert.Equal(404, (await receiver.ChunkAsync("idle", 0, [])).StatusCode);
    }

    [Fact]
    public async Task ReceiverTracksBytesReceivedForSmallMultipartTransfer()
    {
        using var temp = new TemporaryDirectory();
        var bytes = Enumerable.Range(0, 11).Select(i => (byte)i).ToArray();
        const int chunkSize = 4;
        var offer = new FileOfferPayload("small-parts", "test.bin", bytes.Length, "application/octet-stream",
            ContentHasherFor(bytes), chunkSize, 3, DateTimeOffset.UtcNow, "Mac");
        using var receiver = new FileReceiver(Path.Combine(temp.Path, "parts"), () => Path.Combine(temp.Path, "downloads"));
        long bytesReceived = 0;
        receiver.TransferChanged += progress => bytesReceived = progress.BytesTransferred;
        var pairKey = new byte[32];
        Assert.Equal(200, (await receiver.OfferAsync(offer, pairKey, Peer)).StatusCode);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "small-parts");
        for (var index = 0; index < offer.ChunkCount; index++)
        {
            var offset = index * chunkSize;
            var length = Math.Min(chunkSize, bytes.Length - offset);
            await receiver.ChunkAsync("small-parts", index, FileTransferCrypto.SealChunk(key, index, bytes.AsSpan(offset, length)));
        }
        Assert.Equal(bytes.Length, bytesReceived);
    }

    // Robustness: junk chunks, ownership, quota, cleanup.

    [Fact]
    public async Task JunkChunkDoesNotDestroySession()
    {
        using var temp = new TemporaryDirectory();
        using var receiver = NewReceiver(temp);
        var bytes = Enumerable.Range(0, 10).Select(i => (byte)i).ToArray();
        Assert.Equal(200, (await receiver.OfferAsync(SmallOffer("junk", bytes), PairKey, Peer)).StatusCode);
        var key = FileTransferCrypto.DeriveFileKey(PairKey, "junk");

        var junk = await receiver.ChunkAsync("junk", 0, new byte[64]);
        Assert.Equal(400, junk.StatusCode);
        var badIndex = await receiver.ChunkAsync("junk", 99, FileTransferCrypto.SealChunk(key, 0, bytes.AsSpan(0, 4)));
        Assert.Equal((400, "badIndex"), (badIndex.StatusCode, badIndex.Status));
        var badSize = await receiver.ChunkAsync("junk", 0, FileTransferCrypto.SealChunk(key, 0, [9]));
        Assert.Equal((400, "badSize"), (badSize.StatusCode, badSize.Status));

        await SendAllChunks(receiver, "junk", bytes);
        var finished = await receiver.FinishAsync("junk", Peer);
        Assert.Equal(200, finished.StatusCode);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(finished.SavedPath!));
    }

    [Fact]
    public async Task FinishFromDifferentPairedDeviceIsRejected()
    {
        using var temp = new TemporaryDirectory();
        using var receiver = NewReceiver(temp);
        var bytes = new byte[] { 1, 2, 3, 4 };
        await receiver.OfferAsync(SmallOffer("owned", bytes), PairKey, Peer);
        await SendAllChunks(receiver, "owned", bytes);

        Assert.Equal(404, (await receiver.FinishAsync("owned", Other)).StatusCode);
        Assert.Equal(404, (await receiver.CancelAsync("owned", Other)).StatusCode);
        Assert.Equal(200, (await receiver.FinishAsync("owned", Peer)).StatusCode);
    }

    [Fact]
    public async Task FinishWhilePausedIsRejected()
    {
        using var temp = new TemporaryDirectory();
        var backend = new ReceiverBackend(NewReceiver(temp));
        backend.Keys[Peer] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var bytes = new byte[] { 1, 2, 3, 4 };
        Assert.Equal(200, (await Route(router, "/v1/file/offer", Seal(SmallOffer("paused", bytes), EnvelopePurpose.FileOffer))).StatusCode);
        await SendAllChunks(backend.Receiver, "paused", bytes);

        backend.Connected = false;
        Assert.Equal(401, (await Route(router, "/v1/file/finish", Seal(new FileFinishPayload("paused"), EnvelopePurpose.FileFinish))).StatusCode);
        Assert.Equal(401, (await Route(router, "/v1/file/cancel", Seal(new FileCancelPayload("paused"), EnvelopePurpose.FileCancel))).StatusCode);

        backend.Connected = true;
        Assert.Equal(200, (await Route(router, "/v1/file/finish", Seal(new FileFinishPayload("paused"), EnvelopePurpose.FileFinish))).StatusCode);
        backend.Receiver.Dispose();
    }

    [Theory]
    [InlineData("/v1/file/offer")]
    [InlineData("/v1/file/finish")]
    [InlineData("/v1/file/cancel")]
    public async Task FileEndpointAeadFailureIsUnauthorized(string path)
    {
        using var temp = new TemporaryDirectory();
        using var receiver = NewReceiver(temp);
        var backend = new ReceiverBackend(receiver);
        backend.Keys[Peer] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var envelope = Seal(new FileFinishPayload("x"), EnvelopePurpose.FileFinish);
        var forged = Convert.FromBase64String(envelope.Ciphertext);
        forged[0] ^= 0xff;
        Assert.Equal(401, (await Route(router, path, envelope with { Ciphertext = Convert.ToBase64String(forged) })).StatusCode);
    }

    [Fact]
    public async Task OfferLargerThanFreeSpaceIsRejected()
    {
        Assert.Equal(500L * 1024 * 1024, FileTransferConstants.FreeSpaceReserve);
        using var temp = new TemporaryDirectory();
        using var receiver = NewReceiver(temp, freeSpace: FileTransferConstants.FreeSpaceReserve + 1000);
        var tooLarge = await receiver.OfferAsync(Offer("huge", 1001, "h"), PairKey, Peer);
        Assert.Equal((400, "tooLarge"), (tooLarge.StatusCode, tooLarge.Status));
        Assert.Empty(Directory.GetFiles(Path.Combine(temp.Path, "parts")));
        Assert.Equal(200, (await receiver.OfferAsync(Offer("fits", 1000, "h"), PairKey, Peer)).StatusCode);
    }

    [Fact]
    public async Task NinthConcurrentSessionIsRejected()
    {
        Assert.Equal(8, FileTransferConstants.MaxSessionsPerDevice);
        using var temp = new TemporaryDirectory();
        using var receiver = NewReceiver(temp);
        for (var i = 0; i < 8; i++)
            Assert.Equal(200, (await receiver.OfferAsync(Offer($"s{i}", 1, "h"), PairKey, Peer)).StatusCode);
        var ninth = await receiver.OfferAsync(Offer("s8", 1, "h"), PairKey, Peer);
        Assert.Equal((429, "tooManyTransfers"), (ninth.StatusCode, ninth.Status));
        // The limit is per device.
        Assert.Equal(200, (await receiver.OfferAsync(Offer("other", 1, "h"), PairKey, Other)).StatusCode);
    }

    [Fact]
    public async Task FailedWriteDoesNotMarkChunkReceived()
    {
        using var temp = new TemporaryDirectory();
        var failures = 1;
        using var receiver = NewReceiver(temp, chunkWriter: (stream, offset, bytes, token) =>
            failures-- > 0 ? throw new IOException("disk full") : FileReceiver.DefaultChunkWriter(stream, offset, bytes, token));
        var bytes = new byte[] { 1, 2, 3, 4 };
        await receiver.OfferAsync(SmallOffer("write", bytes), PairKey, Peer);
        var body = FileTransferCrypto.SealChunk(FileTransferCrypto.DeriveFileKey(PairKey, "write"), 0, bytes);

        var failed = await receiver.ChunkAsync("write", 0, body);
        Assert.Equal((400, "writeFailed"), (failed.StatusCode, failed.Status));
        Assert.Equal(409, (await receiver.FinishAsync("write", Peer)).StatusCode);

        Assert.Equal(200, (await receiver.ChunkAsync("write", 0, body)).StatusCode);
        var finished = await receiver.FinishAsync("write", Peer);
        Assert.Equal(200, finished.StatusCode);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(finished.SavedPath!));
    }

    [Fact]
    public async Task CancelledIdsArePruned()
    {
        using var temp = new TemporaryDirectory();
        var now = DateTimeOffset.UtcNow;
        using var receiver = NewReceiver(temp, clock: () => now);
        await receiver.OfferAsync(Offer("gone", 3, "h"), PairKey, Peer);
        Assert.Equal(200, (await receiver.CancelAsync("gone", Peer)).StatusCode);
        now += TimeSpan.FromSeconds(599); await receiver.CleanupExpiredAsync();
        Assert.Equal(410, (await receiver.ChunkAsync("gone", 0, [])).StatusCode);
        now += TimeSpan.FromSeconds(2); await receiver.CleanupExpiredAsync();
        Assert.Equal(0, receiver.CancelledTransferCount);
        Assert.Equal(404, (await receiver.ChunkAsync("gone", 0, [])).StatusCode);
    }

    [Fact]
    public async Task FailedFinishLeavesNoZombieSession()
    {
        using var temp = new TemporaryDirectory();
        var parts = Path.Combine(temp.Path, "parts");
        using var receiver = new FileReceiver(parts, () => throw new IOException("no downloads folder"), freeSpaceProvider: () => long.MaxValue);
        var bytes = new byte[] { 1, 2, 3, 4 };
        await receiver.OfferAsync(SmallOffer("zombie", bytes), PairKey, Peer);
        await SendAllChunks(receiver, "zombie", bytes);

        Assert.Equal(422, (await receiver.FinishAsync("zombie", Peer)).StatusCode);
        Assert.Empty(Directory.GetFiles(parts));
        Assert.Equal(404, (await receiver.FinishAsync("zombie", Peer)).StatusCode);
    }

    private static readonly DeviceIdentity Identity = new(Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"), "Windows");

    private static FileReceiver NewReceiver(TemporaryDirectory temp, long freeSpace = long.MaxValue, Func<DateTimeOffset>? clock = null,
        Func<FileStream, long, byte[], CancellationToken, Task>? chunkWriter = null) =>
        new(Path.Combine(temp.Path, "parts"), () => Path.Combine(temp.Path, "downloads"), clock, () => freeSpace, chunkWriter);

    /// <summary>An offer split into 4-byte chunks.</summary>
    private static FileOfferPayload SmallOffer(string id, byte[] bytes) => new(id, "test.bin", bytes.Length,
        "application/octet-stream", ContentHasherFor(bytes), 4, (bytes.Length + 3) / 4, DateTimeOffset.UtcNow, "Mac");

    private static async Task SendAllChunks(FileReceiver receiver, string id, byte[] bytes)
    {
        var key = FileTransferCrypto.DeriveFileKey(PairKey, id);
        for (int index = 0, offset = 0; offset < bytes.Length; index++, offset += 4)
            Assert.Equal(200, (await receiver.ChunkAsync(id, index, FileTransferCrypto.SealChunk(key, index, bytes.AsSpan(offset, Math.Min(4, bytes.Length - offset))))).StatusCode);
    }

    private static ClipEnvelope Seal<T>(T payload, EnvelopePurpose purpose) => EnvelopeCrypto.SealJson(payload, purpose, Peer, Identity.Id, PairKey);

    private static Task<HttpResponse> Route(ClipServerRouter router, string path, ClipEnvelope envelope) => router.RouteAsync(
        new HttpRequest("POST", path, new Dictionary<string, string>(), JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options)),
        "host", TestContext.Current.CancellationToken);

    /// <summary>Routes file endpoints into a real <see cref="FileReceiver"/>.</summary>
    private sealed class ReceiverBackend(FileReceiver receiver) : IClipServerBackend
    {
        public FileReceiver Receiver { get; } = receiver;
        public Dictionary<Guid, byte[]> Keys { get; } = [];
        public bool Connected { get; set; } = true;
        public byte[]? GetPairKey(Guid deviceId) => Keys.GetValueOrDefault(deviceId);
        public bool IsConnected(Guid deviceId) => Connected;
        public ReceiveResult Receive(ClipPayload payload) => throw new InvalidOperationException();
        public Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken cancellationToken) =>
            Receiver.OfferAsync(offer, pairKey, sourceDeviceId, cancellationToken);
        public Task<FileReceiveResult> HandleFileChunkAsync(string transferId, int chunkIndex, byte[] body, CancellationToken cancellationToken) =>
            Receiver.ChunkAsync(transferId, chunkIndex, body, cancellationToken);
        public Task<FileReceiveResult> HandleFileFinishAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
            Receiver.FinishAsync(transferId, sourceDeviceId, cancellationToken);
        public Task<FileReceiveResult> HandleFileCancelAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
            Receiver.CancelAsync(transferId, sourceDeviceId, cancellationToken);
        public Task<PairStartResponse> HandlePairStartAsync(PairStartRequest request, string remoteHost, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
        public Task<PairConfirmOutcome> HandlePairConfirmAsync(PairConfirmRequest request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }

    private static FileOfferPayload Offer(string id, long size, string hash) => new(id, "test.bin", size,
        "application/octet-stream", hash, FileTransferConstants.ChunkSize,
        checked((int)((size + FileTransferConstants.ChunkSize - 1) / FileTransferConstants.ChunkSize)),
        DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), "Mac");
    private static string ContentHasherFor(byte[] bytes) { using var sha = System.Security.Cryptography.SHA256.Create(); return Convert.ToHexString(sha.ComputeHash("file\0"u8.ToArray().Concat(bytes).ToArray())).ToLowerInvariant(); }
}
