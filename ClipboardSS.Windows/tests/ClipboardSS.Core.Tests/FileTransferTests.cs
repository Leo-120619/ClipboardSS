using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Sync;
#pragma warning disable xUnit1051

namespace ClipboardSS.Core.Tests;

public sealed class FileTransferTests
{
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
        Assert.Equal(200, (await receiver.OfferAsync(offer, pairKey)).StatusCode);
        Assert.Equal(409, (await receiver.FinishAsync("abcdef")).StatusCode);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "abcdef");
        var body = FileTransferCrypto.SealChunk(key, 0, bytes);
        Assert.Equal(1, (await receiver.ChunkAsync("abcdef", 0, body)).Received);
        Assert.Equal(1, (await receiver.ChunkAsync("abcdef", 0, body)).Received);
        var finished = await receiver.FinishAsync("abcdef");
        Assert.Equal(200, finished.StatusCode);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(finished.SavedPath!));

        var bad = Offer("bad", bytes.Length, new string('0', 64));
        await receiver.OfferAsync(bad, pairKey);
        await receiver.ChunkAsync("bad", 0, FileTransferCrypto.SealChunk(FileTransferCrypto.DeriveFileKey(pairKey, "bad"), 0, bytes));
        Assert.Equal(422, (await receiver.FinishAsync("bad")).StatusCode);
        Assert.Empty(Directory.GetFiles(Path.Combine(temp.Path, "parts")));

        await receiver.OfferAsync(Offer("cancel", bytes.Length, ContentHasherFor(bytes)), pairKey);
        Assert.Equal(200, (await receiver.CancelAsync("cancel")).StatusCode);
        Assert.Equal(410, (await receiver.ChunkAsync("cancel", 0, [])).StatusCode);
        Assert.Equal(200, (await receiver.CancelAsync("cancel")).StatusCode);
    }

    [Fact]
    public async Task ReceiverAcceptsOutOfOrderChunksAndGarbageCollectsIdleSessions()
    {
        using var temp = new TemporaryDirectory();
        var now = DateTimeOffset.UtcNow;
        using var receiver = new FileReceiver(Path.Combine(temp.Path, "parts"), () => Path.Combine(temp.Path, "downloads"), () => now);
        var pairKey = new byte[32];
        var bytes = new byte[FileTransferConstants.ChunkSize + 3]; new byte[] { 1, 2, 3 }.CopyTo(bytes, bytes.Length - 3);
        await receiver.OfferAsync(Offer("order", bytes.Length, ContentHasherFor(bytes)), pairKey);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "order");
        Assert.Equal(200, (await receiver.ChunkAsync("order", 1, FileTransferCrypto.SealChunk(key, 1, bytes[^3..]))).StatusCode);
        Assert.Equal(200, (await receiver.ChunkAsync("order", 0, FileTransferCrypto.SealChunk(key, 0, bytes.AsSpan(0, FileTransferConstants.ChunkSize)))).StatusCode);
        Assert.Equal(200, (await receiver.FinishAsync("order")).StatusCode);
        await receiver.OfferAsync(Offer("idle", 3, ContentHasherFor([1, 2, 3])), pairKey);
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
        Assert.Equal(200, (await receiver.OfferAsync(offer, pairKey)).StatusCode);
        var key = FileTransferCrypto.DeriveFileKey(pairKey, "small-parts");
        for (var index = 0; index < offer.ChunkCount; index++)
        {
            var offset = index * chunkSize;
            var length = Math.Min(chunkSize, bytes.Length - offset);
            await receiver.ChunkAsync("small-parts", index, FileTransferCrypto.SealChunk(key, index, bytes.AsSpan(offset, length)));
        }
        Assert.Equal(bytes.Length, bytesReceived);
    }

    private static FileOfferPayload Offer(string id, long size, string hash) => new(id, "test.bin", size,
        "application/octet-stream", hash, FileTransferConstants.ChunkSize,
        checked((int)((size + FileTransferConstants.ChunkSize - 1) / FileTransferConstants.ChunkSize)),
        DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), "Mac");
    private static string ContentHasherFor(byte[] bytes) { using var sha = System.Security.Cryptography.SHA256.Create(); return Convert.ToHexString(sha.ComputeHash("file\0"u8.ToArray().Concat(bytes).ToArray())).ToLowerInvariant(); }
}
