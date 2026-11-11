using System.Text;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

public sealed class ReplayGuardTests
{
    private static readonly Guid Source = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Recipient = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly DateTimeOffset Start = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private static readonly byte[] PairKey = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();

    private sealed class Clock(DateTimeOffset start)
    {
        public DateTimeOffset Now { get; set; } = start;
    }

    private static ReplayGuard MakeGuard(Clock clock) =>
        new(TimeSpan.FromSeconds(300), TimeSpan.FromSeconds(600), () => clock.Now);

    [Fact]
    public void FreshMessageIsAccepted() =>
        Assert.Equal(ReplayCheck.Ok, MakeGuard(new Clock(Start)).Check(Source, "AAAAAAAAAAAAAAAB", Start));

    [Fact]
    public void SameNonceTwiceIsReplayed()
    {
        var clock = new Clock(Start);
        var guard = MakeGuard(clock);
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start));
        clock.Now = Start.AddSeconds(5);
        Assert.Equal(ReplayCheck.Replayed, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start));
        // Another sender may reuse the nonce bytes under its own key.
        Assert.Equal(ReplayCheck.Ok, guard.Check(Recipient, "AAAAAAAAAAAAAAAB", Start));
    }

    [Fact]
    public void SentAtFourMinutesOffIsAccepted()
    {
        var guard = MakeGuard(new Clock(Start));
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start.AddMinutes(-4)));
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAC", Start.AddMinutes(4)));
    }

    [Fact]
    public void SentAtTwentyMinutesOffIsStale()
    {
        var guard = MakeGuard(new Clock(Start));
        Assert.Equal(ReplayCheck.Stale, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start.AddMinutes(-20)));
        Assert.Equal(ReplayCheck.Stale, guard.Check(Source, "AAAAAAAAAAAAAAAC", Start.AddMinutes(20)));
        // The window boundary is inclusive.
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAD", Start.AddSeconds(-300)));
        Assert.Equal(ReplayCheck.Stale, guard.Check(Source, "AAAAAAAAAAAAAAAE", Start.AddSeconds(-301)));
        Assert.Equal(ReplayCheck.Stale, guard.Check(Source, "AAAAAAAAAAAAAAAF", DateTimeOffset.MinValue));
    }

    [Fact]
    public void StaleMessageIsNotRemembered()
    {
        var guard = MakeGuard(new Clock(Start));
        Assert.Equal(ReplayCheck.Stale, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start.AddMinutes(-20)));
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start));
    }

    [Fact]
    public void EntriesExpireAfterRetention()
    {
        var clock = new Clock(Start);
        var guard = MakeGuard(clock);
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAB", Start));
        clock.Now = Start.AddSeconds(599);
        Assert.Equal(ReplayCheck.Replayed, guard.Check(Source, "AAAAAAAAAAAAAAAB", clock.Now));
        clock.Now = Start.AddSeconds(601);
        Assert.Equal(ReplayCheck.Ok, guard.Check(Source, "AAAAAAAAAAAAAAAB", clock.Now));
    }

    private sealed record Sample(int A);

    [Fact]
    public void SealStampsSentAtInsideTheEncryptedPayloadInWholeSecondUtc()
    {
        var sentAt = new DateTimeOffset(2026, 11, 10, 12, 0, 0, 456, TimeSpan.Zero);
        var envelope = EnvelopeCrypto.SealJson(new Sample(1), EnvelopePurpose.Clip, Source, Recipient, PairKey, sentAt);
        var plaintext = EnvelopeCrypto.OpenPlaintext(envelope, EnvelopePurpose.Clip, Recipient, PairKey);
        using var document = JsonDocument.Parse(plaintext);
        Assert.Equal("2026-11-10T12:00:00Z", document.RootElement.GetProperty("sentAt").GetString());
        Assert.Equal(1, document.RootElement.GetProperty("a").GetInt32());

        var opened = EnvelopeCrypto.OpenStamped<Sample>(envelope, EnvelopePurpose.Clip, Recipient, PairKey);
        Assert.Equal(new Sample(1), opened.Payload);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_794_312_000), opened.SentAt);
    }

    [Fact]
    public void PayloadWithoutSentAtOpensAsInfinitelyOld()
    {
        var envelope = EnvelopeCrypto.SealPlaintext(
            Encoding.UTF8.GetBytes("{\"a\":1}"), EnvelopePurpose.Clip, Source, Recipient, PairKey);
        Assert.Equal(DateTimeOffset.MinValue,
            EnvelopeCrypto.OpenStamped<Sample>(envelope, EnvelopePurpose.Clip, Recipient, PairKey).SentAt);
    }

    // MARK: - Router (receive paths)

    private static readonly DeviceIdentity Identity = new(Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"), "Windows");

    private static HttpRequest Post(string path, ClipEnvelope envelope) =>
        new("POST", path, new Dictionary<string, string>(), JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options));

    private static ClipPayload Text(string text) => new()
    {
        Id = Guid.NewGuid(),
        Type = ClipType.Text,
        CreatedAt = DateTimeOffset.UtcNow,
        Text = text,
        PreviewText = text,
        ContentHash = ContentHasher.TextHash(text),
        SourceDeviceName = "Mac",
    };

    [Fact]
    public async Task ReplayedClipDoesNotTouchPasteboard()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var request = Post("/v1/clip", EnvelopeCrypto.Seal(Text("secret"), EnvelopePurpose.Clip, Source, Identity.Id, PairKey));

        Assert.Equal(200, (await router.RouteAsync(request, "host", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(1, backend.ReceiveCount);

        var replayed = await router.RouteAsync(request, "host", TestContext.Current.CancellationToken);
        Assert.Equal(409, replayed.StatusCode);
        Assert.Equal("{\"status\":\"replayed\"}", Encoding.UTF8.GetString(replayed.Body));
        Assert.Equal(1, backend.ReceiveCount);
    }

    [Fact]
    public async Task StaleClipIsRejectedAndFourMinuteSkewSyncs()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);

        var stale = await router.RouteAsync(
            Post("/v1/clip", EnvelopeCrypto.Seal(Text("old"), EnvelopePurpose.Clip, Source, Identity.Id, PairKey,
                DateTimeOffset.UtcNow.AddMinutes(-20))),
            "host", TestContext.Current.CancellationToken);
        Assert.Equal(400, stale.StatusCode);
        Assert.Equal("{\"status\":\"stale\"}", Encoding.UTF8.GetString(stale.Body));
        Assert.Equal(0, backend.ReceiveCount);

        var skewed = await router.RouteAsync(
            Post("/v1/clip", EnvelopeCrypto.Seal(Text("skewed"), EnvelopePurpose.Clip, Source, Identity.Id, PairKey,
                DateTimeOffset.UtcNow.AddMinutes(4))),
            "host", TestContext.Current.CancellationToken);
        Assert.Equal(200, skewed.StatusCode);
        Assert.Equal(1, backend.ReceiveCount);
    }

    [Fact]
    public async Task ReplayedOfferAfterFinishIsRejected()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var offer = new FileOfferPayload("transfer", "a.bin", 1, "application/octet-stream", "hash", 4, 1,
            DateTimeOffset.UtcNow, "Mac");
        var offerRequest = Post("/v1/file/offer", EnvelopeCrypto.SealJson(offer, EnvelopePurpose.FileOffer, Source, Identity.Id, PairKey));
        var finishRequest = Post("/v1/file/finish",
            EnvelopeCrypto.SealJson(new FileFinishPayload("transfer"), EnvelopePurpose.FileFinish, Source, Identity.Id, PairKey));

        Assert.Equal(200, (await router.RouteAsync(offerRequest, "host", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(200, (await router.RouteAsync(finishRequest, "host", TestContext.Current.CancellationToken)).StatusCode);

        var replayedOffer = await router.RouteAsync(offerRequest, "host", TestContext.Current.CancellationToken);
        Assert.Equal(409, replayedOffer.StatusCode);
        Assert.Equal("{\"status\":\"replayed\"}", Encoding.UTF8.GetString(replayedOffer.Body));
        var replayedFinish = await router.RouteAsync(finishRequest, "host", TestContext.Current.CancellationToken);
        Assert.Equal(409, replayedFinish.StatusCode);
        Assert.Equal(1, backend.OfferCount);
        Assert.Equal(1, backend.FinishCount);
    }

    [Fact]
    public async Task ReplayedCancelIsRejected()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var cancel = Post("/v1/file/cancel",
            EnvelopeCrypto.SealJson(new FileCancelPayload("transfer"), EnvelopePurpose.FileCancel, Source, Identity.Id, PairKey));
        Assert.Equal(200, (await router.RouteAsync(cancel, "host", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(409, (await router.RouteAsync(cancel, "host", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(1, backend.CancelCount);
    }

    [Fact]
    public async Task StaleOfferCreatesNoSession()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var offer = new FileOfferPayload("transfer", "a.bin", 1, "application/octet-stream", "hash", 4, 1,
            DateTimeOffset.UtcNow, "Mac");
        var response = await router.RouteAsync(
            Post("/v1/file/offer", EnvelopeCrypto.SealJson(offer, EnvelopePurpose.FileOffer, Source, Identity.Id, PairKey,
                DateTimeOffset.UtcNow.AddMinutes(-20))),
            "host", TestContext.Current.CancellationToken);
        Assert.Equal(400, response.StatusCode);
        Assert.Equal("{\"status\":\"stale\"}", Encoding.UTF8.GetString(response.Body));
        Assert.Equal(0, backend.OfferCount);
    }

    [Fact]
    public async Task ForgedEnvelopeDoesNotBurnTheGenuineNonce()
    {
        var backend = new CountingBackend();
        backend.Keys[Source] = PairKey;
        var router = new ClipServerRouter(Identity, backend);
        var envelope = EnvelopeCrypto.Seal(Text("hi"), EnvelopePurpose.Clip, Source, Identity.Id, PairKey);
        var bytes = Convert.FromBase64String(envelope.Ciphertext);
        bytes[0] ^= 0xff;
        var forged = envelope with { Ciphertext = Convert.ToBase64String(bytes) };

        Assert.Equal(400, (await router.RouteAsync(Post("/v1/clip", forged), "host", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(200, (await router.RouteAsync(Post("/v1/clip", envelope), "host", TestContext.Current.CancellationToken)).StatusCode);
    }

    private sealed class CountingBackend : IClipServerBackend
    {
        public Dictionary<Guid, byte[]> Keys { get; } = [];
        public int ReceiveCount { get; private set; }
        public int OfferCount { get; private set; }
        public int FinishCount { get; private set; }
        public int CancelCount { get; private set; }
        public byte[]? GetPairKey(Guid deviceId) => Keys.GetValueOrDefault(deviceId);

        public ReceiveResult Receive(ClipPayload payload)
        {
            ReceiveCount++;
            return new ReceiveResult(ReceiveStatus.Added, null);
        }

        public Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            OfferCount++;
            return Task.FromResult(new FileReceiveResult(200, "ready"));
        }

        public Task<FileReceiveResult> HandleFileFinishAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            FinishCount++;
            return Task.FromResult(new FileReceiveResult(200, "complete"));
        }

        public Task<FileReceiveResult> HandleFileCancelAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken)
        {
            CancelCount++;
            return Task.FromResult(new FileReceiveResult(200, "cancelled"));
        }

        public Task<PairStartResponse> HandlePairStartAsync(PairStartRequest request, string remoteHost, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();

        public Task<PairConfirmOutcome> HandlePairConfirmAsync(PairConfirmRequest request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }
}
