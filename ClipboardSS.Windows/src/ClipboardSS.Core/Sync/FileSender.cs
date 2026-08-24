using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Sync;

public sealed class FileSender(DeviceIdentity identity, PairedDeviceStore pairedStore, IPeerTransport transport)
{
    public async Task SendAsync(string path, Peer peer, IProgress<FileTransferProgress>? progress = null,
        CancellationToken cancellationToken = default, string? transferId = null)
    {
        var pairKey = pairedStore.GetKey(peer.Id) ?? throw new InvalidOperationException("The target device is not paired.");
        transferId = (transferId ?? Guid.NewGuid().ToString("D")).ToLowerInvariant();
        var info = new FileInfo(path);
        await using var hashStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var hash = await ContentHasher.FileHashAsync(hashStream, cancellationToken);
        var chunkCount = checked((int)((info.Length + FileTransferConstants.ChunkSize - 1) / FileTransferConstants.ChunkSize));
        var offer = new FileOfferPayload(transferId, info.Name, info.Length, "application/octet-stream", hash,
            FileTransferConstants.ChunkSize, chunkCount, DateTimeOffset.UtcNow, identity.Name);
        try
        {
            await SendControlAsync("/v1/file/offer", offer, peer, pairKey, cancellationToken);
            var key = FileTransferCrypto.DeriveFileKey(pairKey, transferId);
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                FileTransferConstants.ChunkSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var buffer = new byte[FileTransferConstants.ChunkSize];
            long sent = 0;
            for (var index = 0; index < chunkCount; index++)
            {
                var count = await ReadChunkAsync(stream, buffer, cancellationToken);
                var body = FileTransferCrypto.SealChunk(key, index, buffer.AsSpan(0, count));
                await SendRequestAsync(new HttpRequest("POST", "/v1/file/chunk", new Dictionary<string, string>
                {
                    ["Content-Type"] = "application/octet-stream", ["X-Transfer-Id"] = transferId,
                    ["X-Chunk-Index"] = index.ToString(),
                }, body), peer, cancellationToken);
                sent += count;
                progress?.Report(new(transferId, info.Name, sent, info.Length, FileTransferDirection.Sending, FileTransferStatus.Active));
            }
            await SendControlAsync("/v1/file/finish", new FileFinishPayload(transferId), peer, pairKey, cancellationToken);
            progress?.Report(new(transferId, info.Name, info.Length, info.Length, FileTransferDirection.Sending, FileTransferStatus.Completed));
        }
        catch
        {
            try { await SendControlAsync("/v1/file/cancel", new FileCancelPayload(transferId), peer, pairKey, CancellationToken.None); }
            catch { }
            throw;
        }
    }

    private async Task SendControlAsync<T>(string path, T payload, Peer peer, byte[] key, CancellationToken token)
    {
        var envelope = EnvelopeCrypto.SealJson(payload, identity.Id, key);
        await SendRequestAsync(new HttpRequest("POST", path,
            new Dictionary<string, string> { ["Content-Type"] = "application/json" },
            JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options)), peer, token);
    }

    private async Task SendRequestAsync(HttpRequest request, Peer peer, CancellationToken token)
    {
        var bytes = await transport.SendAsync(HttpCodec.EncodeRequest(request, $"{peer.Host}:{peer.Port}"), peer, token);
        var response = HttpCodec.ParseResponse(bytes);
        if (response.StatusCode != 200) throw new HttpRequestException($"Peer returned HTTP {response.StatusCode}.");
    }

    private static async Task<int> ReadChunkAsync(Stream stream, byte[] buffer, CancellationToken token)
    {
        var count = 0;
        while (count < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(count), token);
            if (read == 0) break;
            count += read;
        }
        return count;
    }
}
