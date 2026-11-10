using System.Text;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

/// <summary>Authenticated liveness: <c>POST /v1/ping</c> and the decisions built on it.</summary>
public sealed class LivenessTests
{
    private static readonly Guid Local = Guid.Parse("aaaaaaaa-0000-0000-0000-000000000000");
    private static readonly Guid Device = Guid.Parse("cccccccc-0000-0000-0000-000000000000");
    private static readonly byte[] Key = Enumerable.Repeat((byte)7, 32).ToArray();

    private static Func<PairedDevice, string, CancellationToken, Task<PingOutcome>> Ping(
        Func<string, PingOutcome> byHost, List<string>? pinged = null) =>
        (_, host, _) =>
        {
            pinged?.Add(host);
            return Task.FromResult(byHost(host));
        };

    // --- decisions ---

    [Fact]
    public async Task ImpostorAnsweringIdIsNotMarkedOnline()
    {
        // The impostor at 10.0.0.66 advertises the paired id over mDNS / /v1/id but has no pair key.
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "Mac", "10.0.0.9")],
            [new Peer(Device, "Mac", "10.0.0.66", 51888)],
            Ping(_ => PingOutcome.Unverified),
            TestContext.Current.CancellationToken);

        Assert.Empty(report.OnlineIds);
    }

    [Fact]
    public async Task HostIsNotUpdatedWithoutValidPong()
    {
        var device = new PairedDevice(Device, "Mac", "10.0.0.9");
        var report = await DeviceLiveness.ResolveAsync(
            [device],
            [new Peer(Device, "Mac", "10.0.0.66", 51888)],
            Ping(host => host == "10.0.0.66" ? PingOutcome.UpgradeRequired : PingOutcome.Unverified),
            TestContext.Current.CancellationToken);

        Assert.Empty(DeviceLiveness.HostUpdates([device], report));
        Assert.Empty(report.OnlineIds);
    }

    [Fact]
    public async Task ValidPongMarksOnlineAndUpdatesHost()
    {
        var device = new PairedDevice(Device, "Mac", "10.0.0.9");
        var pinged = new List<string>();
        var report = await DeviceLiveness.ResolveAsync(
            [device],
            [new Peer(Device, "Mac", "192.168.0.4", 51888)],
            Ping(host => host == "192.168.0.4" ? PingOutcome.Alive : PingOutcome.Unverified, pinged),
            TestContext.Current.CancellationToken);

        Assert.Equal([Device], report.OnlineIds);
        Assert.Equal("192.168.0.4", DeviceLiveness.HostUpdates([device], report)[Device]);
        Assert.Equal(["192.168.0.4"], pinged);
    }

    [Fact]
    public async Task ValidPongClearsAnEarlierUpgradeRequired()
    {
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "Mac", "10.0.0.9")],
            [new Peer(Device, "Mac", "10.0.0.66", 51888)],
            Ping(host => host == "10.0.0.66" ? PingOutcome.UpgradeRequired : PingOutcome.Alive),
            TestContext.Current.CancellationToken);

        Assert.Contains(Device, report.OnlineIds);
        Assert.Empty(report.UpgradeRequired);
    }

    [Fact]
    public async Task UpgradeRequiredEverywhereIsOutdatedNotOnline()
    {
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "PC", "192.168.0.20")], [],
            Ping(_ => PingOutcome.UpgradeRequired),
            TestContext.Current.CancellationToken);

        Assert.Empty(report.OnlineIds);
        Assert.Equal([Device], report.UpgradeRequired);
    }

    [Fact]
    public async Task StaleRefusedPingIsClockSkewNotOnlineAndHostUnchanged()
    {
        var device = new PairedDevice(Device, "Mac", "10.0.0.9");
        var report = await DeviceLiveness.ResolveAsync(
            [device],
            [new Peer(Device, "Mac", "10.0.0.8", 51888)],
            Ping(host => host == "10.0.0.8" ? PingOutcome.ClockSkew : PingOutcome.Unverified),
            TestContext.Current.CancellationToken);

        Assert.Equal([Device], report.ClockSkew);
        Assert.Empty(report.OnlineIds);
        Assert.Empty(DeviceLiveness.HostUpdates([device], report));
    }

    [Fact]
    public async Task ValidPongClearsClockSkewFromAnotherAddress()
    {
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "Mac", "10.0.0.9")],
            [new Peer(Device, "Mac", "10.0.0.8", 51888)],
            Ping(host => host == "10.0.0.8" ? PingOutcome.ClockSkew : PingOutcome.Alive),
            TestContext.Current.CancellationToken);

        Assert.Contains(Device, report.OnlineIds);
        Assert.Empty(report.ClockSkew);
    }

    [Fact]
    public async Task StaleMdnsHostFallsBackToStoredHost()
    {
        var pinged = new List<string>();
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "Mac", "10.0.0.2")],
            [new Peer(Device, "Mac", "10.0.0.3", 51888)],
            Ping(host => host == "10.0.0.2" ? PingOutcome.Alive : PingOutcome.Unverified, pinged),
            TestContext.Current.CancellationToken);

        Assert.Equal("10.0.0.2", report.VerifiedHosts[Device]);
        Assert.Equal(["10.0.0.3", "10.0.0.2"], pinged);
    }

    [Fact]
    public async Task DeviceWithoutHostIsOfflineAndNotPinged()
    {
        var pinged = new List<string>();
        var report = await DeviceLiveness.ResolveAsync(
            [new PairedDevice(Device, "Legacy")], [],
            Ping(_ => PingOutcome.Alive, pinged),
            TestContext.Current.CancellationToken);

        Assert.Empty(report.OnlineIds);
        Assert.Empty(pinged);
    }

    // --- protocol ---

    private static ClipServerRouter Responder(byte[]? knownKey = null, ReplayGuard? replayGuard = null)
    {
        var backend = new KeyBackend();
        backend.Keys[Local] = knownKey ?? Key;
        return new ClipServerRouter(new DeviceIdentity(Device, "Mac"), backend, replayGuard);
    }

    private static Func<byte[], CancellationToken, Task<byte[]>> Wire(ClipServerRouter router) =>
        async (bytes, token) =>
        {
            var request = HttpCodec.ParseRequest(bytes);
            Assert.Equal("POST", request.Method);
            Assert.Equal(LivenessPing.Path, request.Path);
            return HttpCodec.EncodeResponse(await router.RouteAsync(request, "127.0.0.1", token));
        };

    private static Task<PingOutcome> PingDevice(Func<byte[], CancellationToken, Task<byte[]>> send) =>
        LivenessPing.PingAsync("10.0.0.9", Device, Local, Key, send, cancellationToken: TestContext.Current.CancellationToken);

    [Fact]
    public async Task ValidPongFromPairedDeviceIsAlive()
    {
        Assert.Equal(PingOutcome.Alive, await PingDevice(Wire(Responder())));
    }

    [Fact]
    public async Task ImpostorWithoutPairKeyIsUnverified()
    {
        var impostor = Responder(Enumerable.Repeat((byte)9, 32).ToArray());
        Assert.Equal(PingOutcome.Unverified, await PingDevice(Wire(impostor)));
    }

    [Fact]
    public async Task PongCapturedForEarlierPingDoesNotAnswerANewOne()
    {
        var wire = Wire(Responder());
        byte[]? captured = null;
        Assert.Equal(PingOutcome.Alive, await PingDevice(async (bytes, token) => captured = await wire(bytes, token)));
        Assert.Equal(PingOutcome.Unverified, await PingDevice((_, _) => Task.FromResult(captured!)));
    }

    [Fact]
    public void PongFromAnotherDeviceOrStaleIsUnverified()
    {
        var nonce = Convert.ToBase64String(Enumerable.Range(0, 12).Select(value => (byte)value).ToArray());
        byte[] Pong(Guid source, DateTimeOffset sentAt) => JsonSerializer.SerializeToUtf8Bytes(
            EnvelopeCrypto.SealJson(new PongPayload(nonce), EnvelopePurpose.Pong, source, Local, Key, sentAt),
            WireJson.Options);
        var now = DateTimeOffset.UtcNow;

        Assert.Equal(PingOutcome.Unverified,
            LivenessPing.EvaluatePong(200, Pong(Guid.NewGuid(), now), nonce, Device, Local, Key, now));
        Assert.Equal(PingOutcome.Unverified,
            LivenessPing.EvaluatePong(200, Pong(Device, now.AddSeconds(-301)), nonce, Device, Local, Key, now));
        Assert.Equal(PingOutcome.Alive,
            LivenessPing.EvaluatePong(200, Pong(Device, now.AddSeconds(-240)), nonce, Device, Local, Key, now));
    }

    [Fact]
    public void UpgradeRequiredAndNonPongAnswers()
    {
        Assert.Equal(PingOutcome.UpgradeRequired, LivenessPing.EvaluatePong(426, [], "AAAAAAAAAAAAAAAB", Device, Local, Key));
        Assert.Equal(PingOutcome.Unverified, LivenessPing.EvaluatePong(
            200, Encoding.UTF8.GetBytes("{\"deviceId\":\"x\",\"v\":2}"), "AAAAAAAAAAAAAAAB", Device, Local, Key));
        Assert.Equal(PingOutcome.Unverified, LivenessPing.EvaluatePong(401, [], "AAAAAAAAAAAAAAAB", Device, Local, Key));
        Assert.Equal(PingOutcome.ClockSkew, LivenessPing.EvaluatePong(
            400, "{\"status\":\"stale\"}"u8.ToArray(), "AAAAAAAAAAAAAAAB", Device, Local, Key));
        Assert.Equal(PingOutcome.Unverified, LivenessPing.EvaluatePong(
            400, "Bad Request"u8.ToArray(), "AAAAAAAAAAAAAAAB", Device, Local, Key));
    }

    [Fact]
    public async Task ResponderAnswers401StaleAndReplayed()
    {
        var router = Responder(replayGuard: new ReplayGuard());
        async Task<int> Send(ClipEnvelope envelope) => (await router.RouteAsync(
            new HttpRequest("POST", LivenessPing.Path, new Dictionary<string, string>(),
                JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options)),
            "127.0.0.1", TestContext.Current.CancellationToken)).StatusCode;

        var ping = EnvelopeCrypto.SealJson(new PingPayload(), EnvelopePurpose.Ping, Local, Device, Key);
        Assert.Equal(401, await Send(EnvelopeCrypto.SealJson(new PingPayload(), EnvelopePurpose.Ping, Guid.NewGuid(), Device, Key)));
        Assert.Equal(401, await Send(EnvelopeCrypto.SealJson(new PingPayload(), EnvelopePurpose.Clip, Local, Device, Key)));
        Assert.Equal(400, await Send(EnvelopeCrypto.SealJson(
            new PingPayload(), EnvelopePurpose.Ping, Local, Device, Key, DateTimeOffset.UtcNow.AddSeconds(-301))));
        Assert.Equal(200, await Send(ping));
        Assert.Equal(409, await Send(ping));
    }

    [Theory]
    [InlineData(EnvelopePurpose.Ping, "ping", "127e1dfb0b3bc52649f874034b63d5fa53c0a4886a60a1")]
    [InlineData(EnvelopePurpose.Pong, "pong", "127e1dfb0b3bc535d219b680a4ddb08aac15ee49a426c4")]
    public void PingAndPongMatchPinnedVectors(EnvelopePurpose purpose, string wireName, string expectedHex)
    {
        var pairKey = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var source = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var recipient = Guid.Parse("22222222-2222-2222-2222-222222222222");
        Assert.Equal(
            $"ClipboardSS/2|{wireName}|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222",
            Encoding.UTF8.GetString(EnvelopeCrypto.AssociatedData(purpose, source, recipient)));
        var envelope = EnvelopeCrypto.SealPlaintext(
            Encoding.UTF8.GetBytes("{\"a\":1}"), purpose, source, recipient, pairKey, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        Assert.Equal(expectedHex, Convert.ToHexString(Convert.FromBase64String(envelope.Ciphertext)).ToLowerInvariant());
    }

    // --- mDNS peer table ---

    [Fact]
    public void MdnsGoodbyeRemovesPeer()
    {
        var table = new MdnsPeerTable();
        var now = DateTimeOffset.UtcNow;
        table.Upsert("mac._clipboardss._tcp.local", new Peer(Device, "Mac", "mac.local", 51888), TimeSpan.FromMinutes(75), now);

        Assert.True(table.Remove("MAC._clipboardss._tcp.local"));
        Assert.Empty(table.Peers);
    }

    [Fact]
    public void MdnsPeerExpiresWhenTtlRunsOut()
    {
        var table = new MdnsPeerTable();
        var now = DateTimeOffset.UtcNow;
        table.Upsert("mac._clipboardss._tcp.local", new Peer(Device, "Mac", "mac.local", 51888), TimeSpan.FromSeconds(120), now);

        Assert.False(table.Prune(now.AddSeconds(119)));
        Assert.Single(table.Peers);
        Assert.True(table.Prune(now.AddSeconds(120)));
        Assert.Empty(table.Peers);
    }

    [Fact]
    public void MdnsRefreshExtendsTtlAndReplacesAddress()
    {
        var table = new MdnsPeerTable();
        var now = DateTimeOffset.UtcNow;
        table.Upsert("mac._clipboardss._tcp.local", new Peer(Device, "Mac", "10.0.0.2", 51888), TimeSpan.FromSeconds(120), now);
        table.Upsert("mac._clipboardss._tcp.local", new Peer(Device, "Mac", "10.0.0.3", 51888), TimeSpan.FromSeconds(120), now.AddSeconds(100));

        Assert.False(table.Prune(now.AddSeconds(150)));
        Assert.Equal("10.0.0.3", Assert.Single(table.Peers).Host);
    }

    private sealed class KeyBackend : IClipServerBackend
    {
        public Dictionary<Guid, byte[]> Keys { get; } = [];
        public byte[]? GetPairKey(Guid deviceId) => Keys.GetValueOrDefault(deviceId);
        public bool IsConnected(Guid deviceId) => false; // a paused peer still answers liveness
        public ReceiveResult Receive(ClipPayload payload) => throw new InvalidOperationException("not expected");
        public Task<PairStartResponse> HandlePairStartAsync(PairStartRequest request, string remoteHost, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("not expected");
        public Task<PairConfirmOutcome> HandlePairConfirmAsync(PairConfirmRequest request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("not expected");
    }
}
