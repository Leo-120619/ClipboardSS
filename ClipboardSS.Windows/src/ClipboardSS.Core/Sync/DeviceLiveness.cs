using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Sync;

/// <summary>Outcome of pinging paired devices: who answered a valid pong, and where.</summary>
public sealed class LivenessReport
{
    /// <summary>Devices that answered a valid pong, keyed to the host that answered.</summary>
    public Dictionary<Guid, string> VerifiedHosts { get; } = [];
    /// <summary>Devices that answered 426 and no valid pong.</summary>
    public HashSet<Guid> UpgradeRequired { get; } = [];

    public IReadOnlySet<Guid> OnlineIds => VerifiedHosts.Keys.ToHashSet();

    public void Merge(LivenessReport other)
    {
        foreach (var (id, host) in other.VerifiedHosts) VerifiedHosts.TryAdd(id, host);
        UpgradeRequired.UnionWith(other.UpgradeRequired);
        UpgradeRequired.ExceptWith(VerifiedHosts.Keys);
    }
}

/// <summary>
/// Liveness decisions. mDNS and the stored address only nominate hosts; a paired device is online,
/// and its stored host moves, only at a host that answered a valid pong (see <see cref="LivenessPing"/>).
/// Independent of <see cref="PairedDevice.Connected"/>, which is a local pause switch.
/// </summary>
public static class DeviceLiveness
{
    /// <summary>Hosts to ping for a device: its current mDNS address(es), then the stored one.</summary>
    public static IReadOnlyList<string> CandidateHosts(PairedDevice device, IEnumerable<Peer> mdnsPeers)
    {
        var hosts = mdnsPeers
            .Where(peer => peer.Id == device.Id && !string.IsNullOrWhiteSpace(peer.Host))
            .Select(peer => peer.Host)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (!string.IsNullOrWhiteSpace(device.Host) && !hosts.Contains(device.Host, StringComparer.OrdinalIgnoreCase))
            hosts.Add(device.Host);
        return hosts;
    }

    /// <summary>Pings <paramref name="hosts"/> in order and stops at the first valid pong.</summary>
    public static async Task<LivenessReport> VerifyAsync(
        PairedDevice device,
        IEnumerable<string> hosts,
        Func<PairedDevice, string, CancellationToken, Task<PingOutcome>> ping,
        CancellationToken cancellationToken = default)
    {
        var report = new LivenessReport();
        foreach (var host in hosts)
        {
            switch (await ping(device, host, cancellationToken))
            {
                case PingOutcome.Alive:
                    report.VerifiedHosts[device.Id] = host;
                    report.UpgradeRequired.Remove(device.Id);
                    return report;
                case PingOutcome.UpgradeRequired:
                    report.UpgradeRequired.Add(device.Id);
                    break;
            }
        }
        return report;
    }

    /// <summary>Pings every paired device concurrently, mDNS address first, then the stored one.</summary>
    public static async Task<LivenessReport> ResolveAsync(
        IEnumerable<PairedDevice> devices,
        IEnumerable<Peer> mdnsPeers,
        Func<PairedDevice, string, CancellationToken, Task<PingOutcome>> ping,
        CancellationToken cancellationToken = default)
    {
        var peers = mdnsPeers.ToArray();
        var partials = await Task.WhenAll(devices.Select(device =>
            VerifyAsync(device, CandidateHosts(device, peers), ping, cancellationToken)));
        var report = new LivenessReport();
        foreach (var partial in partials) report.Merge(partial);
        return report;
    }

    /// <summary>Stored-host changes a report calls for: devices whose pong came from a host other than the stored one.</summary>
    public static IReadOnlyDictionary<Guid, string> HostUpdates(IEnumerable<PairedDevice> devices, LivenessReport report)
    {
        var updates = new Dictionary<Guid, string>();
        foreach (var device in devices)
            if (report.VerifiedHosts.TryGetValue(device.Id, out var host) && host != device.Host)
                updates[device.Id] = host;
        return updates;
    }
}
