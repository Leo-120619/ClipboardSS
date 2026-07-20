using ClipboardSS.App.Net;
using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Tests;

public sealed class DeviceLivenessTests
{
    [Fact]
    public async Task MdnsPeerIsOnlineWithoutAHostProbe()
    {
        var id = Guid.NewGuid();
        var probeCalls = 0;

        var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
            [new PairedDevice(id, "Phone", "10.0.0.2")],
            [new Peer(id, "Phone", "10.0.0.2", 51888)],
            (_, _) => { probeCalls++; return Task.FromResult<Peer?>(null); },
            TestContext.Current.CancellationToken);

        Assert.Contains(id, online);
        Assert.Equal(0, probeCalls);
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
