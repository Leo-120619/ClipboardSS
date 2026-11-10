using System.Net;
using System.Net.Sockets;
using ClipboardSS.Core.Protocol;

namespace ClipboardSS.App.Net;

public sealed class TcpClipServer(ClipServerRouter router, int port = 51888) : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Any, port);
    private CancellationTokenSource? _cancellation;
    private Task? _acceptLoop;

    public bool IsRunning => _acceptLoop is { IsCompleted: false };

    public void Start()
    {
        if (IsRunning) return;
        try
        {
            _listener.Start();
        }
        catch (SocketException exception)
        {
            throw new InvalidOperationException(
                "ClipboardSS could not listen on TCP 51888. Close the Flutter Windows companion or another process using that port, then restart ClipboardSS.",
                exception);
        }

        _cancellation = new CancellationTokenSource();
        _acceptLoop = AcceptLoopAsync(_cancellation.Token);
    }

    public async ValueTask DisposeAsync()
    {
        if (_cancellation is null) return;
        await _cancellation.CancelAsync();
        _listener.Stop();
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop;
            }
            catch (OperationCanceledException)
            {
            }
            catch (SocketException)
            {
            }
        }

        _cancellation.Dispose();
        _cancellation = null;
        _acceptLoop = null;
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var client = await _listener.AcceptTcpClientAsync(cancellationToken);
            _ = HandleClientAsync(client, cancellationToken);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        await using (var stream = client.GetStream())
        {
            HttpResponse response;
            try
            {
                var request = HttpCodec.ParseRequest(await ReadRequestAsync(stream, cancellationToken));
                var remoteHost = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? string.Empty;
                response = await router.RouteAsync(request, remoteHost, cancellationToken);
            }
            catch (HttpCodecException exception) when (exception.Error == HttpCodecError.PayloadTooLarge)
            {
                response = new HttpResponse(413, new Dictionary<string, string>(), "Payload Too Large"u8.ToArray());
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                response = new HttpResponse(400, new Dictionary<string, string>(), "Bad Request"u8.ToArray());
            }

            var bytes = HttpCodec.EncodeResponse(response);
            await stream.WriteAsync(bytes, cancellationToken);
        }
    }

    private static async Task<byte[]> ReadRequestAsync(
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
                _ = HttpCodec.ParseRequest(finalBytes);
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
                _ = HttpCodec.ParseRequest(bytes);
                return bytes;
            }
            catch (HttpCodecException exception) when (exception.Error == HttpCodecError.Incomplete)
            {
            }
        }
    }
}
