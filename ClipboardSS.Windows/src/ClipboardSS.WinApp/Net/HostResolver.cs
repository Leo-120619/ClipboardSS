using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;

namespace ClipboardSS.App.Net;

/// <summary>
/// Resolves peer host names to addresses. A paired device is stored under its mDNS name
/// (<c>Name.local</c>), and Windows answers <c>.local</c> lookups unreliably: the same name resolves
/// one second and fails with "no data of the requested type" the next. A failed lookup is retried
/// once and then falls back to the addresses the name last resolved to. That is safe because every
/// request is sealed with the pair key: a wrong host cannot read or forge anything.
/// </summary>
public sealed class HostResolver(
    Func<string, CancellationToken, Task<IPAddress[]>>? lookup = null,
    TimeSpan? retryDelay = null)
{
    public static HostResolver Shared { get; } = new();

    private readonly Func<string, CancellationToken, Task<IPAddress[]>> _lookup =
        lookup ?? ((host, cancellationToken) => Dns.GetHostAddressesAsync(host, cancellationToken));
    private readonly TimeSpan _retryDelay = retryDelay ?? TimeSpan.FromMilliseconds(250);
    private readonly ConcurrentDictionary<string, IPAddress[]> _lastKnown = new(StringComparer.OrdinalIgnoreCase);

    public async Task<IPAddress[]> ResolveAsync(string host, CancellationToken cancellationToken = default)
    {
        if (IPAddress.TryParse(host, out var literal)) return [literal];

        SocketException? failure = null;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (attempt > 0) await Task.Delay(_retryDelay, cancellationToken);
            try
            {
                var addresses = await _lookup(host, cancellationToken);
                if (addresses.Length > 0)
                {
                    _lastKnown[host] = addresses;
                    return addresses;
                }
            }
            catch (SocketException exception)
            {
                failure = exception;
            }
        }

        if (_lastKnown.TryGetValue(host, out var cached)) return cached;
        throw failure ?? new SocketException((int)SocketError.HostNotFound);
    }
}
