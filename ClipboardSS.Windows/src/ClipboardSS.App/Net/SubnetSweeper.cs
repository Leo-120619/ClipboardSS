using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;

namespace ClipboardSS.App.Net;

public sealed class SubnetSweeper(TimeSpan? timeout = null, int concurrency = 32)
{
    private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromMilliseconds(500);
    private readonly int _concurrency = concurrency;

    public async Task<IReadOnlyList<Peer>> SweepAsync(CancellationToken cancellationToken = default)
    {
        var localAddresses = GetLocalIpv4Addresses().ToArray();
        var hosts = localAddresses.SelectMany(HostAddresses).Distinct().ToArray();
        var peers = new ConcurrentDictionary<Guid, Peer>();
        await Parallel.ForEachAsync(
            hosts,
            new ParallelOptions
            {
                MaxDegreeOfParallelism = _concurrency,
                CancellationToken = cancellationToken,
            },
            async (host, token) =>
            {
                var peer = await ProbeAsync(host, token);
                if (peer is not null) peers[peer.Id] = peer;
            });
        return peers.Values.OrderBy(peer => peer.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    /// <summary>Probes one known host for its ClipboardSS identity.</summary>
    public Task<Peer?> ProbeHostAsync(string host, CancellationToken cancellationToken = default) =>
        ProbeAsync(host, cancellationToken);

    internal static IReadOnlyList<string> HostAddresses(string ownIpv4)
    {
        if (!IPAddress.TryParse(ownIpv4, out var address)) return [];
        var bytes = address.GetAddressBytes();
        if (bytes.Length != 4) return [];
        return Enumerable.Range(1, 254)
            .Select(last => $"{bytes[0]}.{bytes[1]}.{bytes[2]}.{last}")
            .Where(candidate => candidate != ownIpv4)
            .ToArray();
    }

    private static IEnumerable<string> GetLocalIpv4Addresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up
                && network.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses)
            .Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(address => address.Address.ToString());

    private async Task<Peer?> ProbeAsync(string host, CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(_timeout);
        try
        {
            var transport = new TcpPeerTransport(_timeout);
            var probe = new Peer(Guid.Empty, host, host, 51888);
            var request = new HttpRequest("GET", "/v1/id", new Dictionary<string, string>(), []);
            var responseBytes = await transport.SendAsync(
                HttpCodec.EncodeRequest(request, $"{host}:51888"),
                probe,
                timeoutSource.Token);
            var response = HttpCodec.ParseResponse(responseBytes);
            if (response.StatusCode != 200) return null;
            var identity = JsonSerializer.Deserialize<IdentityResponse>(response.Body, WireJson.Options);
            return identity is null
                ? null
                : new Peer(identity.DeviceId, identity.DeviceName, host, 51888);
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    private sealed record IdentityResponse(Guid DeviceId, string DeviceName, int V);
}
