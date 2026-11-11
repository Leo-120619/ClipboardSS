namespace ClipboardSS.Core.Protocol;

/// <summary>Outcome of a freshness / replay check on an opened envelope.</summary>
public enum ReplayCheck
{
    Ok,

    /// <summary>
    /// <c>|now - sentAt|</c> exceeds the freshness window: the clocks disagree, or the envelope
    /// is old. Receivers answer <c>400 {"status":"stale"}</c>.
    /// </summary>
    Stale,

    /// <summary>
    /// The <c>(sourceDeviceId, nonce)</c> pair was already accepted within the retention period.
    /// Receivers answer <c>409 {"status":"replayed"}</c>.
    /// </summary>
    Replayed,
}

/// <summary>
/// Rejects stale and replayed envelopes. Call <see cref="Check"/> only after the AEAD open
/// succeeded (so <c>sentAt</c> is authenticated and junk never fills the set), and before any
/// side effect. One instance per receiver process, shared by every envelope endpoint.
/// Thread-safe. See docs/wire-protocol.md ("Freshness and replay protection").
/// </summary>
public sealed class ReplayGuard(TimeSpan? window = null, TimeSpan? retention = null, Func<DateTimeOffset>? now = null)
{
    public static readonly TimeSpan DefaultWindow = TimeSpan.FromSeconds(300);
    public static readonly TimeSpan DefaultRetention = TimeSpan.FromSeconds(600);

    private readonly TimeSpan _window = window ?? DefaultWindow;
    private readonly TimeSpan _retention = retention ?? DefaultRetention;
    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly object _lock = new();

    /// <summary>Accepted <c>(source, nonce)</c> keys and when they were accepted.</summary>
    private readonly Dictionary<string, DateTimeOffset> _seen = [];

    public ReplayCheck Check(Guid sourceDeviceId, string nonce, DateTimeOffset sentAt)
    {
        lock (_lock)
        {
            var current = _now();
            var cutoff = current - _retention;
            foreach (var expired in _seen.Where(entry => entry.Value < cutoff).Select(entry => entry.Key).ToArray())
            {
                _seen.Remove(expired);
            }

            // Compare in ticks so DateTimeOffset.MinValue (missing sentAt) cannot overflow.
            if (Math.Abs((double)current.UtcTicks - sentAt.UtcTicks) > _window.Ticks) return ReplayCheck.Stale;

            var key = Key(sourceDeviceId, nonce);
            if (_seen.ContainsKey(key)) return ReplayCheck.Replayed;
            _seen[key] = current;
            return ReplayCheck.Ok;
        }
    }

    /// <summary>Keys on the decoded nonce bytes so another spelling of the same nonce cannot slip past.</summary>
    private static string Key(Guid sourceDeviceId, string nonce)
    {
        string canonicalNonce;
        try
        {
            canonicalNonce = Convert.ToBase64String(Convert.FromBase64String(nonce));
        }
        catch (FormatException)
        {
            canonicalNonce = nonce;
        }
        return $"{sourceDeviceId.ToString("D").ToLowerInvariant()}|{canonicalNonce}";
    }
}
