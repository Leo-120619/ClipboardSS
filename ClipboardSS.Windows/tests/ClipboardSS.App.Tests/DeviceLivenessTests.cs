using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Tests;

/// <summary>
/// AppModel routing statics. The ping-based liveness decisions (impostor, host update, valid pong)
/// live in ClipboardSS.Core and are tested in ClipboardSS.Core.Tests/LivenessTests.cs.
/// </summary>
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
    public void FileTargetIgnoresMdnsClaimedAddress()
    {
        var id = Guid.NewGuid();
        var device = new PairedDevice(id, "Mac", "10.0.0.9");

        Assert.Equal("10.0.0.9",
            AppModel.ResolveVerifiedPeer(device, true, [new Peer(id, "Mac", "10.0.0.66", 51888)])?.Host);
    }

    [Fact]
    public void FileTargetFromStoredHostKeepsOlderVersionFlag()
    {
        var id = Guid.NewGuid();
        var device = new PairedDevice(id, "Mac", "10.0.0.9");

        Assert.True(AppModel.ResolveVerifiedPeer(device, true, [], new HashSet<Guid> { id })?.NeedsUpdate);
        Assert.False(AppModel.ResolveVerifiedPeer(device, true, [])?.NeedsUpdate);
    }

    [Fact]
    public void SendTargetsUseStoredHostNeverMdnsClaimedAddress()
    {
        var id = Guid.NewGuid();
        var oldId = Guid.NewGuid();
        var targets = AppModel.ComposeSendTargets(
            [new Peer(id, "Mac", "10.0.0.66", 51888), new Peer(oldId, "Old", "10.0.0.67", 51888, 1)],
            [new PairedDevice(id, "Mac", "10.0.0.9"), new PairedDevice(oldId, "Old", "10.0.0.30")]);

        Assert.Equal("10.0.0.9", targets.Single(peer => peer.Id == id).Host);
        Assert.True(targets.Single(peer => peer.Id == oldId).NeedsUpdate);
        Assert.Equal("10.0.0.30", targets.Single(peer => peer.Id == oldId).Host);
    }
}
