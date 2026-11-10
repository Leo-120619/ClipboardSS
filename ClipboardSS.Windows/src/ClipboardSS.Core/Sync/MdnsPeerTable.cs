using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Sync;

/// <summary>
/// Peers seen over mDNS, keyed by service instance name. A goodbye (TTL 0) removes a peer at once,
/// and a peer whose record TTL runs out without a refresh is pruned. Thread-safe.
/// </summary>
public sealed class MdnsPeerTable
{
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _byService = new(StringComparer.OrdinalIgnoreCase);

    private sealed record Entry(Peer Peer, DateTimeOffset ExpiresAt);

    /// <summary>Current peers, one per device id (the most recently seen wins).</summary>
    public IReadOnlyList<Peer> Peers
    {
        get
        {
            lock (_lock)
            {
                return _byService.Values
                    .OrderBy(entry => entry.ExpiresAt)
                    .GroupBy(entry => entry.Peer.Id)
                    .Select(group => group.Last().Peer)
                    .ToArray();
            }
        }
    }

    /// <summary>Records <paramref name="peer"/> as advertised by <paramref name="serviceName"/> for <paramref name="ttl"/>.</summary>
    public void Upsert(string serviceName, Peer peer, TimeSpan ttl, DateTimeOffset now)
    {
        lock (_lock) _byService[serviceName] = new Entry(peer, now + ttl);
    }

    /// <summary>Removes the peer behind <paramref name="serviceName"/> (an mDNS goodbye). True if one was removed.</summary>
    public bool Remove(string serviceName)
    {
        lock (_lock) return _byService.Remove(serviceName);
    }

    /// <summary>Drops peers whose TTL has run out. True if any was removed.</summary>
    public bool Prune(DateTimeOffset now)
    {
        lock (_lock)
        {
            var expired = _byService.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToArray();
            foreach (var key in expired) _byService.Remove(key);
            return expired.Length > 0;
        }
    }
}
