using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Net;

public static class DeviceLiveness
{
    public static async Task<HashSet<Guid>> ResolveOnlineDeviceIdsAsync(
        IEnumerable<PairedDevice> devices,
        IEnumerable<Peer> mdnsPeers,
        Func<string, CancellationToken, Task<Peer?>> probeHost,
        CancellationToken cancellationToken = default)
    {
        var discoveredPeers = mdnsPeers
            .GroupBy(peer => peer.Id)
            .ToDictionary(group => group.Key, group => group.Last());
        var pairedDevices = devices.ToArray();
        var probes = pairedDevices
            .Select(async device =>
            {
                var candidateHosts = new List<string>(2);
                if (discoveredPeers.TryGetValue(device.Id, out var discovered)
                    && !string.IsNullOrWhiteSpace(discovered.Host))
                {
                    candidateHosts.Add(discovered.Host);
                }
                if (!string.IsNullOrWhiteSpace(device.Host)
                    && !candidateHosts.Contains(device.Host, StringComparer.OrdinalIgnoreCase))
                {
                    candidateHosts.Add(device.Host);
                }

                foreach (var host in candidateHosts)
                {
                    var peer = await probeHost(host, cancellationToken);
                    if (peer?.Id == device.Id) return (Guid?)device.Id;
                }

                return null;
            });

        var onlineIds = new HashSet<Guid>();
        foreach (var deviceId in await Task.WhenAll(probes))
            if (deviceId is Guid id) onlineIds.Add(id);

        return onlineIds;
    }
}
