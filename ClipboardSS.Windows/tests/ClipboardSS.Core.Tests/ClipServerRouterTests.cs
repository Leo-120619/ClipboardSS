using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

public sealed class ClipServerRouterTests
{
    private static readonly DeviceIdentity Identity = new(
        Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"),
        "Windows");

    [Fact]
    public async Task IdentityRouteReturnsCanonicalJson()
    {
        var router = new ClipServerRouter(Identity, new FakeBackend());

        var response = await router.RouteAsync(
            Request("GET", "/v1/id"),
            "192.168.0.2",
            TestContext.Current.CancellationToken);

        Assert.Equal(200, response.StatusCode);
        Assert.Equal(
            "{\"deviceId\":\"8fb5790c-4533-47bb-90af-827291247fe1\",\"deviceName\":\"Windows\",\"v\":1}",
            System.Text.Encoding.UTF8.GetString(response.Body));
    }

    [Fact]
    public async Task ClipRouteRejectsUnpairedAndReportsOkOrDuplicate()
    {
        var backend = new FakeBackend();
        var router = new ClipServerRouter(Identity, backend);
        var sourceId = Guid.NewGuid();
        var payload = TextPayload("hello");
        var key = Enumerable.Repeat((byte)7, 32).ToArray();
        var envelope = EnvelopeCrypto.Seal(payload, sourceId, key);
        var request = Request(
            "POST",
            "/v1/clip",
            JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options));

        Assert.Equal(
            401,
            (await router.RouteAsync(request, "host", TestContext.Current.CancellationToken)).StatusCode);

        backend.Keys[sourceId] = key;
        var added = await router.RouteAsync(request, "host", TestContext.Current.CancellationToken);
        Assert.Equal("{\"status\":\"ok\"}", System.Text.Encoding.UTF8.GetString(added.Body));

        backend.ReceiveStatus = ReceiveStatus.Duplicate;
        var duplicate = await router.RouteAsync(request, "host", TestContext.Current.CancellationToken);
        Assert.Equal("{\"status\":\"duplicate\"}", System.Text.Encoding.UTF8.GetString(duplicate.Body));
    }

    [Fact]
    public async Task PairRoutesUseExpectedStatusesAndCaptureRemoteHost()
    {
        var backend = new FakeBackend();
        var router = new ClipServerRouter(Identity, backend);
        var start = new PairStartRequest(Guid.NewGuid(), "Mac", Convert.ToBase64String(new byte[32]));

        var response = await router.RouteAsync(
            Request("POST", "/v1/pair/start", JsonSerializer.SerializeToUtf8Bytes(start, WireJson.Options)),
            "192.168.0.9",
            TestContext.Current.CancellationToken);
        Assert.Equal(200, response.StatusCode);
        Assert.Equal("192.168.0.9", backend.RemoteHost);

        backend.ConfirmResult = false;
        var confirm = new PairConfirmRequest(start.DeviceId, Convert.ToBase64String(new byte[32]));
        response = await router.RouteAsync(
            Request("POST", "/v1/pair/confirm", JsonSerializer.SerializeToUtf8Bytes(confirm, WireJson.Options)),
            "192.168.0.9",
            TestContext.Current.CancellationToken);
        Assert.Equal(401, response.StatusCode);

        backend.RejectPairStart = true;
        response = await router.RouteAsync(
            Request("POST", "/v1/pair/start", JsonSerializer.SerializeToUtf8Bytes(start, WireJson.Options)),
            "192.168.0.9",
            TestContext.Current.CancellationToken);
        Assert.Equal(403, response.StatusCode);
    }

    [Theory]
    [InlineData("Android Device", "Android Device")]
    [InlineData("Leonardo’s MacBook", "Leonardo's MacBook")]
    [InlineData("Café ☕", "Caf ")]
    public void BonjourTxtSanitizerMatchesMac(string input, string expected) =>
        Assert.Equal(expected, ClipServerRouter.BonjourSafeTxtValue(input));

    private static HttpRequest Request(string method, string path, byte[]? body = null) =>
        new(method, path, new Dictionary<string, string>(), body ?? []);

    private static ClipPayload TextPayload(string text) => new()
    {
        Id = Guid.NewGuid(),
        Type = ClipType.Text,
        CreatedAt = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000),
        Text = text,
        PreviewText = text,
        ContentHash = ContentHasher.TextHash(text),
        SourceDeviceName = "Mac",
    };

    private sealed class FakeBackend : IClipServerBackend
    {
        public Dictionary<Guid, byte[]> Keys { get; } = [];
        public ReceiveStatus ReceiveStatus { get; set; } = ReceiveStatus.Added;
        public string? RemoteHost { get; private set; }
        public bool ConfirmResult { get; set; } = true;
        public bool RejectPairStart { get; set; }
        public byte[]? GetPairKey(Guid deviceId) => Keys.GetValueOrDefault(deviceId);
        public ReceiveResult Receive(ClipPayload payload) => new(ReceiveStatus, null);

        public Task<PairStartResponse> HandlePairStartAsync(
            PairStartRequest request,
            string remoteHost,
            CancellationToken cancellationToken)
        {
            if (RejectPairStart) throw new InvalidOperationException("Not hosting.");
            RemoteHost = remoteHost;
            return Task.FromResult(new PairStartResponse(
                Identity.Id,
                Identity.Name,
                Convert.ToBase64String(new byte[32])));
        }

        public Task<bool> HandlePairConfirmAsync(
            PairConfirmRequest request,
            CancellationToken cancellationToken) => Task.FromResult(ConfirmResult);
    }
}
