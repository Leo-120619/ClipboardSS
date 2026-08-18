using ClipboardSS.App.Net;
using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Tests;

public sealed class DeviceLivenessTests
{
    [Theory]
    [InlineData(true, true, true)]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    public void DisconnectIsShownOnlyForEnabledOnlineDevices(bool enabled, bool online, bool expected)
    {
        Assert.Equal(expected, AppModel.IsDeviceConnectionActive(enabled, online));
    }

    [Fact]
    public void ReconnectionSelectsMatchingDeviceAtRefreshedAddress()
    {
        var target = Guid.NewGuid();
        var peer = AppModel.MatchingReconnectPeer(
            target,
            [new Peer(Guid.NewGuid(), "Other", "10.0.0.8", 51888)],
            [new Peer(target, "Target", "10.0.0.42", 51888)]);

        Assert.Equal("10.0.0.42", peer?.Host);
    }

    [Fact]
    public void FileTargetResolutionRejectsOfflineAndPausedDevices()
    {
        var id = Guid.NewGuid();
        var enabled = new PairedDevice(id, "Mac", "10.0.0.9");
        var paused = enabled with { Connected = false };

        Assert.Null(AppModel.ResolveVerifiedPeer(enabled, false, []));
        Assert.Null(AppModel.ResolveVerifiedPeer(paused, true, []));
        Assert.Equal("10.0.0.9", AppModel.ResolveVerifiedPeer(enabled, true, [])?.Host);
    }

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
