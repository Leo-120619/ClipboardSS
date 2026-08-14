using ClipboardSS.App.Net;
using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Tests;

public sealed class DeviceLivenessTests
{
    [Fact]
    public async Task MdnsPeerMustAnswerWithMatchingIdentityToBeOnline()
    {
        var id = Guid.NewGuid();
        var probedHosts = new List<string>();

        var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
            [new PairedDevice(id, "Phone", "10.0.0.2")],
            [new Peer(id, "Phone", "10.0.0.3", 51888)],
            (host, _) =>
            {
                probedHosts.Add(host);
                return Task.FromResult<Peer?>(null);
            },
            TestContext.Current.CancellationToken);

        Assert.Empty(online);
        Assert.Equal(["10.0.0.3", "10.0.0.2"], probedHosts);
    }

    [Fact]
    public async Task CurrentMdnsHostIsProbedBeforeStoredHost()
    {
        var id = Guid.NewGuid();
        var probedHosts = new List<string>();

        var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
            [new PairedDevice(id, "Mac", "10.0.0.2")],
            [new Peer(id, "Mac", "10.0.0.3", 51888)],
            (host, _) =>
            {
                probedHosts.Add(host);
                return Task.FromResult<Peer?>(
                    host == "10.0.0.3" ? new Peer(id, "Mac", host, 51888) : null);
            },
            TestContext.Current.CancellationToken);

        Assert.Contains(id, online);
        Assert.Equal(["10.0.0.3"], probedHosts);
    }

    [Fact]
    public async Task MatchingHostProbeMarksDeviceOnline()
    {
        var id = Guid.NewGuid();
        var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
            [new PairedDevice(id, "Mac", "10.0.0.3")], [],
            (host, _) => Task.FromResult<Peer?>(new Peer(id, "Mac", host, 51888)),
            TestContext.Current.CancellationToken);

        Assert.Contains(id, online);
    }

    [Fact]
    public async Task FailedOrMismatchedHostProbeLeavesDeviceOffline()
    {
        var id = Guid.NewGuid();
        var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
            [new PairedDevice(id, "Tablet", "10.0.0.4")], [],
            (_, _) => Task.FromResult<Peer?>(new Peer(Guid.NewGuid(), "Other", "10.0.0.4", 51888)),
            TestContext.Current.CancellationToken);

        Assert.DoesNotContain(id, online);
    }
}
