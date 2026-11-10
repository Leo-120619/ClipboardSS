using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using ClipboardSS.Core.Protocol;

namespace ClipboardSS.App.Net;

public sealed class TcpClipServer(ClipServerRouter router, int port = 51888) : IAsyncDisposable
{
    /// <summary>Time an accepted connection has to deliver one complete request.</summary>
    private static readonly TimeSpan RequestDeadline = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan AcceptRetryDelay = TimeSpan.FromMilliseconds(100);
    private const int MaxConcurrentConnections = 64;

    private readonly TcpListener _listener = new(IPAddress.Any, port);
    private readonly SemaphoreSlim _connectionSlots = new(MaxConcurrentConnections, MaxConcurrentConnections);
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
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(cancellationToken);
            }
            catch (SocketException exception) when (!cancellationToken.IsCancellationRequested)
            {
                // A failed accept (e.g. a peer resetting mid-handshake) must not end the listener.
                Debug.WriteLine($"TcpClipServer: accept failed ({exception.SocketErrorCode}); continuing");
                await Task.Delay(AcceptRetryDelay, cancellationToken);
                continue;
            }

            if (!_connectionSlots.Wait(0))
            {
                // At capacity: close the excess connection immediately rather than queueing it.
                client.Dispose();
                continue;
            }

            _ = HandleClientAsync(client, cancellationToken);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        try
        {
            using (client)
            await using (var stream = client.GetStream())
            {
                var remoteHost = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? string.Empty;
                HttpResponse response;
                try
                {
                    var request = await ReadRequestWithDeadlineAsync(stream, cancellationToken);
                    if (request is null) return;
                    response = await router.RouteAsync(request, remoteHost, cancellationToken);
                }
                catch (HttpCodecException exception) when (exception.Error == HttpCodecError.PayloadTooLarge)
                {
                    response = new HttpResponse(413, new Dictionary<string, string>(), "Payload Too Large"u8.ToArray());
                }
                catch (HttpCodecException exception) when (exception.Error == HttpCodecError.HeadersTooLarge)
                {
                    response = new HttpResponse(
                        431,
                        new Dictionary<string, string>(),
                        "Request Header Fields Too Large"u8.ToArray());
                }
                catch (Exception) when (!cancellationToken.IsCancellationRequested)
                {
                    response = new HttpResponse(400, new Dictionary<string, string>(), "Bad Request"u8.ToArray());
                }

                var bytes = HttpCodec.EncodeResponse(response);
                await stream.WriteAsync(bytes, cancellationToken);
            }
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            // The peer went away while we were responding; nothing else to do.
        }
        finally
        {
            _connectionSlots.Release();
        }
    }

    /// <summary>
    /// Reads one request, giving up (null, connection dropped without a reply) if it is not
    /// complete within <see cref="RequestDeadline"/>.
    /// </summary>
    private static async Task<HttpRequest?> ReadRequestWithDeadlineAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(RequestDeadline);
        try
        {
            return await HttpRequestReader.ReadAsync(stream, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Debug.WriteLine("TcpClipServer: request deadline exceeded; dropping connection");
            return null;
        }
    }
}
