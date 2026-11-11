using System.Text;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

public sealed class EnvelopeV2Tests
{
    // Pinned vector — must match docs/wire-protocol.md byte-for-byte.
    private static readonly byte[] PairKey = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
    private static readonly Guid Source = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Recipient = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly byte[] PinnedNonce = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
    private static readonly byte[] PinnedPlaintext = Encoding.UTF8.GetBytes("{\"a\":1}");
    private const string PinnedCiphertextHex = "127e1dfb0b3bc54f07dfeda46cd545278be6adeef430c1";

    private sealed record Sample(int A);

    [Fact]
    public void AssociatedDataBindsVersionPurposeSourceAndRecipientInLowercase()
    {
        var aad = EnvelopeCrypto.AssociatedData(EnvelopePurpose.FileOffer, Source, Recipient);
        Assert.Equal(
            "ClipboardSS/2|file-offer|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222",
            Encoding.UTF8.GetString(aad));
    }

    [Fact]
    public void EnvelopeV2MatchesPinnedVector()
    {
        var envelope = EnvelopeCrypto.SealPlaintext(
            PinnedPlaintext, EnvelopePurpose.Clip, Source, Recipient, PairKey, PinnedNonce);

        Assert.Equal(2, envelope.V);
        Assert.Equal(Convert.ToBase64String(PinnedNonce), envelope.Nonce);
        Assert.Equal(PinnedCiphertextHex, Convert.ToHexString(Convert.FromBase64String(envelope.Ciphertext)).ToLowerInvariant());
        Assert.Equal(PinnedPlaintext, EnvelopeCrypto.OpenPlaintext(envelope, EnvelopePurpose.Clip, Recipient, PairKey));
    }

    [Fact]
    public void RoundTripsATypedPayload()
    {
        var envelope = EnvelopeCrypto.SealJson(new Sample(7), EnvelopePurpose.Clip, Source, Recipient, PairKey);
        Assert.Equal(2, envelope.V);
        Assert.Equal(new Sample(7), EnvelopeCrypto.OpenJson<Sample>(envelope, EnvelopePurpose.Clip, Recipient, PairKey));
    }

    [Theory]
    [InlineData(EnvelopePurpose.Clip)]
    [InlineData(EnvelopePurpose.FileFinish)]
    [InlineData(EnvelopePurpose.FileCancel)]
    public void OpenFailsWithWrongPurpose(EnvelopePurpose purpose)
    {
        var envelope = EnvelopeCrypto.SealJson(new Sample(1), EnvelopePurpose.FileOffer, Source, Recipient, PairKey);
        Assert.Throws<EnvelopeCryptoException>(() =>
            EnvelopeCrypto.OpenJson<Sample>(envelope, purpose, Recipient, PairKey));
    }

    [Fact]
    public void OpenFailsWhenReflectedToSender()
    {
        var envelope = EnvelopeCrypto.SealJson(new Sample(1), EnvelopePurpose.Clip, Source, Recipient, PairKey);
        var reflected = envelope with { SourceDeviceId = Recipient };

        Assert.Throws<EnvelopeCryptoException>(() =>
            EnvelopeCrypto.OpenJson<Sample>(reflected, EnvelopePurpose.Clip, Source, PairKey));
        Assert.Throws<EnvelopeCryptoException>(() =>
            EnvelopeCrypto.OpenJson<Sample>(envelope, EnvelopePurpose.Clip, Source, PairKey));
    }

    [Fact]
    public void OpenFailsWithWrongRecipient()
    {
        var envelope = EnvelopeCrypto.SealJson(new Sample(1), EnvelopePurpose.Clip, Source, Recipient, PairKey);
        Assert.Throws<EnvelopeCryptoException>(() =>
            EnvelopeCrypto.OpenJson<Sample>(envelope, EnvelopePurpose.Clip, Guid.NewGuid(), PairKey));
    }

    [Fact]
    public void OpenRejectsV1AsUnsupported()
    {
        var envelope = EnvelopeCrypto.SealJson(new Sample(1), EnvelopePurpose.Clip, Source, Recipient, PairKey) with { V = 1 };
        var error = Assert.Throws<UnsupportedEnvelopeVersionException>(() =>
            EnvelopeCrypto.OpenJson<Sample>(envelope, EnvelopePurpose.Clip, Recipient, PairKey));
        Assert.Equal(1, error.Version);
    }

    [Theory]
    [InlineData("/v1/clip")]
    [InlineData("/v1/file/offer")]
    [InlineData("/v1/file/finish")]
    [InlineData("/v1/file/cancel")]
    [InlineData("/v1/ping")]
    public async Task V1EnvelopeGetsUpgradeRequired(string path)
    {
        var identity = new DeviceIdentity(Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"), "Windows");
        var backend = new UpgradeBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(identity, backend);
        // A real v1 envelope from a paired peer: it must not be reported as unauthorized.
        var body = Encoding.UTF8.GetBytes(
            "{\"v\":1,\"sourceDeviceId\":\"11111111-1111-1111-1111-111111111111\"," +
            "\"nonce\":\"AAAAAAAAAAAAAAAB\",\"ciphertext\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}");

        var response = await router.RouteAsync(
            new HttpRequest("POST", path, new Dictionary<string, string>(), body),
            "host",
            TestContext.Current.CancellationToken);

        Assert.Equal(426, response.StatusCode);
        Assert.Equal("{\"status\":\"upgradeRequired\",\"minVersion\":2}", Encoding.UTF8.GetString(response.Body));
        Assert.False(backend.Touched);
    }

    [Fact]
    public async Task RouterOpensForItsOwnIdAndPurpose()
    {
        var identity = new DeviceIdentity(Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"), "Windows");
        var backend = new UpgradeBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(identity, backend);
        var offer = new FileOfferPayload(
            "transfer", "test.txt", 4, "text/plain", "hash", 4, 1,
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), "Mac");
        var offerEnvelope = EnvelopeCrypto.SealJson(offer, EnvelopePurpose.FileOffer, Source, identity.Id, PairKey);

        async Task<int> Post(string path, ClipEnvelope envelope) => (await router.RouteAsync(
            new HttpRequest("POST", path, new Dictionary<string, string>(),
                JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options)),
            "host",
            TestContext.Current.CancellationToken)).StatusCode;

        // A captured offer cannot finish or cancel the transfer.
        Assert.NotEqual(200, await Post("/v1/file/finish", offerEnvelope));
        Assert.NotEqual(200, await Post("/v1/file/cancel", offerEnvelope));
        Assert.False(backend.Touched);

        // An offer addressed to another device is rejected.
        var misaddressed = EnvelopeCrypto.SealJson(offer, EnvelopePurpose.FileOffer, Source, Guid.NewGuid(), PairKey);
        Assert.NotEqual(200, await Post("/v1/file/offer", misaddressed));
        Assert.False(backend.Touched);

        Assert.Equal(200, await Post("/v1/file/offer", offerEnvelope));
        Assert.True(backend.Touched);
    }

    private sealed class UpgradeBackend : IClipServerBackend
    {
        public Dictionary<Guid, byte[]> Keys { get; } = [];
        public bool Touched { get; private set; }
        public byte[]? GetPairKey(Guid deviceId) => Keys.GetValueOrDefault(deviceId);

        public ReceiveResult Receive(ClipPayload payload)
        {
            Touched = true;
            throw new InvalidOperationException("not expected");
        }

        public Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            Touched = true;
            return Task.FromResult(new FileReceiveResult(200, "ready"));
        }

        public Task<FileReceiveResult> HandleFileFinishAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            Touched = true;
            return Task.FromResult(new FileReceiveResult(200, "complete"));
        }

        public Task<FileReceiveResult> HandleFileCancelAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            Touched = true;
            return Task.FromResult(new FileReceiveResult(200, "cancelled"));
        }

        public Task<PairStartResponse> HandlePairStartAsync(PairStartRequest request, string remoteHost, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();

        public Task<PairConfirmOutcome> HandlePairConfirmAsync(PairConfirmRequest request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }
}
