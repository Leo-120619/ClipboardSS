using System.Net;
using System.Net.Sockets;
using ClipboardSS.App.Net;

namespace ClipboardSS.App.Tests;

public sealed class HostResolverTests
{
    private static readonly IPAddress[] Mac = [IPAddress.Parse("192.168.0.25")];

    [Fact]
    public async Task AnAddressLiteralIsNotLookedUp()
    {
        var resolver = new HostResolver((_, _) => throw new InvalidOperationException("no lookup expected"));

        Assert.Equal(Mac, await resolver.ResolveAsync("192.168.0.25", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AFailedLookupIsRetriedOnce()
    {
        var calls = 0;
        var resolver = new HostResolver(
            (_, _) => ++calls == 1 ? throw new SocketException((int)SocketError.NoData) : Task.FromResult(Mac),
            TimeSpan.Zero);

        Assert.Equal(Mac, await resolver.ResolveAsync("Mac.local", TestContext.Current.CancellationToken));
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task ANameThatStopsResolvingFallsBackToItsLastAddresses()
    {
        var failing = false;
        var resolver = new HostResolver(
            (_, _) => failing ? throw new SocketException((int)SocketError.NoData) : Task.FromResult(Mac),
            TimeSpan.Zero);
        await resolver.ResolveAsync("Mac.local", TestContext.Current.CancellationToken);
        failing = true;

        Assert.Equal(Mac, await resolver.ResolveAsync("mac.LOCAL", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ANameThatNeverResolvedStillFails()
    {
        var resolver = new HostResolver((_, _) => throw new SocketException((int)SocketError.NoData), TimeSpan.Zero);

        await Assert.ThrowsAsync<SocketException>(() => resolver.ResolveAsync("Mac.local", TestContext.Current.CancellationToken));
    }
}
