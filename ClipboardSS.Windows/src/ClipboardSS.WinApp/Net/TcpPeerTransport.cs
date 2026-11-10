using System.Net.Sockets;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Net;

public sealed class TcpPeerTransport(TimeSpan? timeout = null) : IPeerTransport
{
    private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromSeconds(10);

    public async Task<byte[]> SendAsync(
        byte[] data,
        Peer peer,
        CancellationToken cancellationToken = default)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(_timeout);
        using var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(peer.Host, peer.Port, timeoutSource.Token);
            await using var stream = client.GetStream();
            await stream.WriteAsync(data, timeoutSource.Token);
            await stream.FlushAsync(timeoutSource.Token);
            return await ReadResponseAsync(stream, timeoutSource.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"Timed out connecting to {peer.Host}:{peer.Port}.");
        }
    }

    private static async Task<byte[]> ReadResponseAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(chunk, cancellationToken);
            if (count == 0)
            {
                var finalBytes = buffer.ToArray();
                _ = HttpCodec.ParseResponse(finalBytes);
                return finalBytes;
            }

            buffer.Write(chunk, 0, count);
            if (buffer.Length > HttpCodec.MaxBodySize + (64 * 1024))
            {
                throw new HttpCodecException(HttpCodecError.PayloadTooLarge);
            }

            var bytes = buffer.ToArray();
            try
            {
                _ = HttpCodec.ParseResponse(bytes);
                return bytes;
            }
            catch (HttpCodecException exception) when (exception.Error == HttpCodecError.Incomplete)
            {
            }
        }
    }
}
