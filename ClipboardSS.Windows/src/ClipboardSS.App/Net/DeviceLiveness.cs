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
        var discoveredIds = mdnsPeers.Select(peer => peer.Id).ToHashSet();
        var pairedDevices = devices.ToArray();
        var onlineIds = pairedDevices
            .Where(device => discoveredIds.Contains(device.Id))
            .Select(device => device.Id)
            .ToHashSet();

        var probes = pairedDevices
            .Where(device => !onlineIds.Contains(device.Id) && !string.IsNullOrWhiteSpace(device.Host))
            .Select(async device =>
            {
                var peer = await probeHost(device.Host!, cancellationToken);
                return peer?.Id == device.Id ? device.Id : (Guid?)null;
            });

        foreach (var deviceId in await Task.WhenAll(probes))
            if (deviceId is Guid id) onlineIds.Add(id);

        return onlineIds;
    }
}
