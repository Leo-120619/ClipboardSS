using System.Text;
using System.Text.Json;
using ClipboardSS.App.Pairing;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

// The coordinator lives in WinApp; it is linked into this project (see the csproj) so these tests run off Windows.
public sealed class PairingCoordinatorTests : IDisposable
{
    private static readonly Guid InitiatorA = Guid.Parse("550e8400-e29b-41d4-a716-446655440000");
    private static readonly Guid InitiatorB = Guid.Parse("6fa459ea-ee8a-3ca4-894e-db77e160355e");
    private readonly DeviceIdentity _identity = new(Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1"), "Windows");
    private readonly TemporaryDirectory _directory = new();
    private readonly PairedDeviceStore _store;
    private readonly PairingCoordinator _coordinator;
    private int _hostingChanges;
    private DateTimeOffset _now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    public PairingCoordinatorTests()
    {
        _store = NewStore("target");
        _coordinator = new PairingCoordinator(_identity, _store, new UnusedPeerTransport(), () => _now);
        _coordinator.HostingChanged += (_, _) => Interlocked.Increment(ref _hostingChanges);
    }

    public void Dispose() => _directory.Dispose();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    [Fact]
    public async Task ConfirmWithWrongProofInvalidatesCode()
    {
        var code = _coordinator.StartHosting();
        var initiation = await StartAsync(InitiatorA, code);

        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, new byte[32]));
        Assert.Null(_coordinator.HostCode);
        Assert.Null(_coordinator.HostComparison);

        // The correct proof no longer works, and a fresh start is refused: the user must generate a new code.
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, initiation.Proof));
        await Assert.ThrowsAsync<PairingRejectedException>(() => StartAsync(InitiatorA, code));
        Assert.Null(_store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task ConfirmAfterCodeExpiryIsRejected()
    {
        var code = _coordinator.StartHosting(TimeSpan.FromSeconds(180));
        var initiation = await StartAsync(InitiatorA, code);
        _coordinator.ConfirmHostedPairing();

        _now += TimeSpan.FromSeconds(181);
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, initiation.Proof));
        Assert.Null(_store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task ConfirmAfterStopHostingIsRejected()
    {
        var code = _coordinator.StartHosting();
        var initiation = await StartAsync(InitiatorA, code);

        _coordinator.StopHosting();
        Assert.Null(_coordinator.HostComparison);
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, initiation.Proof));
        Assert.Null(_store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task SecondInitiatorWhilePendingIsRejected()
    {
        var code = _coordinator.StartHosting();
        var first = await StartAsync(InitiatorA, code);

        await Assert.ThrowsAsync<PairingRejectedException>(() => StartAsync(InitiatorB, code));

        // The refused start did not displace the pending initiator.
        _coordinator.ConfirmHostedPairing();
        Assert.Equal(PairConfirmOutcome.Paired, await ConfirmAsync(InitiatorA, first.Proof));
        Assert.Equal(first.PairKey, _store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task SecondStartFromSameInitiatorReplacesPending()
    {
        var code = _coordinator.StartHosting();
        await StartWithoutRevealAsync(InitiatorA);
        var second = await StartAsync(InitiatorA, code);

        _coordinator.ConfirmHostedPairing();
        Assert.Equal(PairConfirmOutcome.Paired, await ConfirmAsync(InitiatorA, second.Proof));
        Assert.Equal(second.PairKey, _store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task ConfirmForAlreadyPairedDeviceIdIsRejected()
    {
        var existingKey = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        _store.AddDevice(new PairedDevice(InitiatorA, "Existing"), existingKey);

        var code = _coordinator.StartHosting();
        var initiation = await StartAsync(InitiatorA, code);
        _coordinator.ConfirmHostedPairing();

        Assert.Equal(PairConfirmOutcome.AlreadyPaired, await ConfirmAsync(InitiatorA, initiation.Proof));
        Assert.Equal(existingKey, _store.GetKey(InitiatorA));
        Assert.Equal(["Existing"], _store.Devices.Select(device => device.Name));
    }

    [Fact]
    public async Task StartHostingClearsPreviousPendingState()
    {
        var oldCode = _coordinator.StartHosting();
        var stale = await StartAsync(InitiatorA, oldCode);

        var newCode = _coordinator.StartHosting();
        Assert.Null(_coordinator.HostComparison);

        // The stale initiator no longer occupies the new code...
        await StartAsync(InitiatorB, newCode);

        // ...and its old proof cannot complete pairing.
        _coordinator.ConfirmHostedPairing();
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, stale.Proof));
        Assert.Null(_store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task RevealWithWrongKeyInvalidatesCode()
    {
        var code = _coordinator.StartHosting();
        var started = await StartWithoutRevealAsync(InitiatorA);

        var outcome = await _coordinator.HandlePairRevealAsync(
            new PairRevealRequest(InitiatorA, Convert.ToBase64String(new PairingSession().EphemeralPublicKey), Convert.ToBase64String(started.Salt)),
            Token);
        Assert.Equal(PairRevealOutcome.Invalid, outcome);
        Assert.Null(_coordinator.HostCode);
        Assert.Null(_coordinator.HostComparison);

        // The honest reveal is now refused too, and so is a fresh start on the same code.
        var honest = await _coordinator.HandlePairRevealAsync(
            new PairRevealRequest(InitiatorA, Convert.ToBase64String(started.Session.EphemeralPublicKey), Convert.ToBase64String(started.Salt)),
            Token);
        Assert.Equal(PairRevealOutcome.Rejected, honest);
        await Assert.ThrowsAsync<PairingRejectedException>(() => StartAsync(InitiatorA, code));
    }

    [Fact]
    public async Task KeysAreNotStoredUntilBothConfirm()
    {
        var (initiator, initiatorStore, _) = NewInitiator();
        var code = _coordinator.StartHosting();

        var comparison = await initiator.StartPairingAsync(TargetPeer, code, Token);
        var hosted = Assert.IsType<PairingComparison>(_coordinator.HostComparison);
        Assert.Equal(hosted.ConfirmCode, comparison.ConfirmCode);
        Assert.Equal("Windows", comparison.DeviceName);
        Assert.Equal("Laptop", hosted.DeviceName);
        Assert.Equal(comparison, initiator.JoinComparison);
        Assert.Empty(initiatorStore.Devices);
        Assert.Empty(_store.Devices);

        // The initiator's user confirms; the target holds the request for its own user.
        var confirming = initiator.ConfirmPairingAsync(Token);
        await WaitUntilConfirmIsHeldAsync();
        Assert.Empty(initiatorStore.Devices);
        Assert.Empty(_store.Devices);

        _coordinator.ConfirmHostedPairing();
        await confirming;

        var initiatorKey = Assert.IsType<byte[]>(initiatorStore.GetKey(_identity.Id));
        Assert.Equal(initiatorKey, _store.GetKey(InitiatorA));
        Assert.Null(_coordinator.HostComparison);
        Assert.Null(initiator.JoinComparison);
    }

    [Fact]
    public async Task TargetCancelRejectsInitiator()
    {
        var (initiator, initiatorStore, _) = NewInitiator();
        var code = _coordinator.StartHosting();

        await initiator.StartPairingAsync(TargetPeer, code, Token);
        var confirming = initiator.ConfirmPairingAsync(Token);
        await WaitUntilConfirmIsHeldAsync();
        _coordinator.CancelHostedPairing();

        var exception = await Assert.ThrowsAsync<PairingNotAcceptedException>(() => confirming);
        Assert.Equal(401, exception.StatusCode);
        Assert.Empty(initiatorStore.Devices);
        Assert.Empty(_store.Devices);
        Assert.Null(_coordinator.HostCode);
        Assert.Null(_coordinator.HostComparison);
        Assert.Null(initiator.JoinComparison);
    }

    [Fact]
    public async Task InitiatorOnlyContactsSelectedPeer()
    {
        var (initiator, _, loopback) = NewInitiator();
        var code = _coordinator.StartHosting();

        await initiator.StartPairingAsync(TargetPeer, code, Token);
        _coordinator.ConfirmHostedPairing();
        await initiator.ConfirmPairingAsync(Token);

        Assert.Equal(["/v1/pair/start", "/v1/pair/reveal", "/v1/pair/confirm"], loopback.Requests.Select(request => request.Path));
        Assert.Equal(["10.0.0.2"], loopback.Requests.Select(request => request.Host).Distinct());
    }

    [Fact]
    public async Task ConfirmTimesOutAfter60s()
    {
        Assert.Equal(TimeSpan.FromSeconds(60), PairingCoordinator.DefaultConfirmHoldTimeout);
        Assert.True(PairingCoordinator.DefaultConfirmRequestTimeout > PairingCoordinator.DefaultConfirmHoldTimeout);
        var coordinator = new PairingCoordinator(
            _identity, _store, new UnusedPeerTransport(), () => _now, confirmHoldTimeout: TimeSpan.FromMilliseconds(50));
        var code = coordinator.StartHosting();
        var initiation = await StartAsync(InitiatorA, code, coordinator);

        var outcome = await coordinator.HandlePairConfirmAsync(
            new PairConfirmRequest(InitiatorA, Convert.ToBase64String(initiation.Proof)), Token);
        Assert.Equal(PairConfirmOutcome.TimedOut, outcome);
        Assert.Null(coordinator.HostCode);
        Assert.Null(coordinator.HostComparison);
        Assert.Null(_store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task HostingChangedFiresOnFailureAndExpiry()
    {
        _coordinator.StartHosting();
        await StartWithoutRevealAsync(InitiatorA);
        var beforeFailure = _hostingChanges;
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, new byte[32]));
        Assert.Null(_coordinator.HostComparison);
        Assert.True(_hostingChanges > beforeFailure);

        _coordinator.StartHosting(TimeSpan.FromMilliseconds(20));
        var beforeExpiry = _hostingChanges;
        _now += TimeSpan.FromSeconds(1);
        for (var i = 0; i < 100 && _hostingChanges == beforeExpiry; i++) await Task.Delay(10, Token);
        Assert.True(_hostingChanges > beforeExpiry);
        Assert.Null(_coordinator.HostCode);
    }

    [Fact]
    public async Task InitiatorSurfacesAlreadyPairedConflict()
    {
        var target = new DeviceIdentity(Guid.NewGuid(), "Mac");
        var startBody = JsonSerializer.SerializeToUtf8Bytes(
            new PairStartResponse(target.Id, target.Name, Convert.ToBase64String(new PairingSession().EphemeralPublicKey)),
            WireJson.Options);
        var json = new Dictionary<string, string> { ["Content-Type"] = "application/json" };
        var transport = new ScriptedPeerTransport(
            HttpCodec.EncodeResponse(new HttpResponse(200, json, startBody)),
            HttpCodec.EncodeResponse(new HttpResponse(200, json, Encoding.UTF8.GetBytes("{\"status\":\"ok\"}"))),
            HttpCodec.EncodeResponse(new HttpResponse(409, json, Encoding.UTF8.GetBytes("{\"status\":\"alreadyPaired\"}"))));
        var store = NewStore("initiator");
        var initiator = new PairingCoordinator(_identity, store, transport, () => _now);

        await initiator.StartPairingAsync(new Peer(target.Id, target.Name, "10.0.0.2", 51888), "123456", Token);
        var exception = await Assert.ThrowsAsync<PairingAlreadyPairedException>(() => initiator.ConfirmPairingAsync(Token));
        Assert.Equal("Remove the existing pairing on the other device first", exception.Message);
        Assert.Empty(store.Devices);
        Assert.Null(initiator.JoinComparison);
    }

    private Peer TargetPeer => new(_identity.Id, _identity.Name, "10.0.0.2", 51888);

    private PairedDeviceStore NewStore(string name) =>
        new(Path.Combine(_directory.Path, $"{name}-paired-devices.json"), new InMemoryPairKeyStorage());

    private (PairingCoordinator Initiator, PairedDeviceStore Store, LoopbackPeerTransport Loopback) NewInitiator()
    {
        var loopback = new LoopbackPeerTransport(new ClipServerRouter(_identity, new CoordinatorBackend(_coordinator)));
        var store = NewStore("initiator");
        var initiator = new PairingCoordinator(new DeviceIdentity(InitiatorA, "Laptop"), store, loopback, () => _now);
        return (initiator, store, loopback);
    }

    private async Task WaitUntilConfirmIsHeldAsync()
    {
        for (var i = 0; i < 500 && !_coordinator.IsHoldingConfirm; i++) await Task.Delay(2, Token);
        Assert.True(_coordinator.IsHoldingConfirm);
    }

    /// <summary>Plays the initiator side of <c>/v1/pair/start</c> only: a commitment to a fresh key.</summary>
    private async Task<(PairingSession Session, byte[] Salt, byte[] TargetPublicKey)> StartWithoutRevealAsync(
        Guid initiatorId,
        PairingCoordinator? coordinator = null)
    {
        var session = new PairingSession();
        var salt = PairingSession.RandomSalt();
        var response = await (coordinator ?? _coordinator).HandlePairStartAsync(
            new PairStartRequest(initiatorId, "Initiator", Convert.ToBase64String(PairingSession.Commitment(session.EphemeralPublicKey, salt))),
            "10.0.0.9",
            Token);
        return (session, salt, Convert.FromBase64String(response.EphemeralPublicKey));
    }

    /// <summary>Plays <c>/v1/pair/start</c> and <c>/v1/pair/reveal</c>, and derives the proof the initiator would confirm with.</summary>
    private async Task<(byte[] PairKey, byte[] Proof)> StartAsync(Guid initiatorId, string code, PairingCoordinator? coordinator = null)
    {
        var target = coordinator ?? _coordinator;
        var started = await StartWithoutRevealAsync(initiatorId, target);
        var reveal = await target.HandlePairRevealAsync(
            new PairRevealRequest(initiatorId, Convert.ToBase64String(started.Session.EphemeralPublicKey), Convert.ToBase64String(started.Salt)),
            Token);
        if (reveal != PairRevealOutcome.Ok) throw new PairingRejectedException($"reveal {reveal}");
        var result = started.Session.CompletePairing(started.TargetPublicKey, true, code);
        return (result.PairKey, PairingSession.GenerateConfirmationProof(result.PairKey, initiatorId, _identity.Id));
    }

    private Task<PairConfirmOutcome> ConfirmAsync(Guid initiatorId, byte[] proof) =>
        _coordinator.HandlePairConfirmAsync(new PairConfirmRequest(initiatorId, Convert.ToBase64String(proof)), Token);

    /// <summary>Delivers each request to a target's real router in-process, recording where it was sent.</summary>
    private sealed class LoopbackPeerTransport(ClipServerRouter router) : IPeerTransport
    {
        public List<(string Host, string Path)> Requests { get; } = [];

        public async Task<byte[]> SendAsync(byte[] data, Peer peer, CancellationToken cancellationToken = default)
        {
            var request = HttpCodec.ParseRequest(data);
            lock (Requests) Requests.Add((peer.Host, request.Path));
            var response = await router.RouteAsync(request, "10.0.0.9", cancellationToken);
            return HttpCodec.EncodeResponse(response);
        }
    }

    /// <summary>The pairing part of AppModel's backend: forwards the pair routes to the coordinator.</summary>
    private sealed class CoordinatorBackend(PairingCoordinator coordinator) : IClipServerBackend
    {
        public byte[]? GetPairKey(Guid deviceId) => null;
        public ReceiveResult Receive(ClipPayload payload) => throw new InvalidOperationException();
        public Task<PairStartResponse> HandlePairStartAsync(PairStartRequest request, string remoteHost, CancellationToken cancellationToken) =>
            coordinator.HandlePairStartAsync(request, remoteHost, cancellationToken);
        public Task<PairRevealOutcome> HandlePairRevealAsync(PairRevealRequest request, CancellationToken cancellationToken) =>
            coordinator.HandlePairRevealAsync(request, cancellationToken);
        public Task<PairConfirmOutcome> HandlePairConfirmAsync(PairConfirmRequest request, CancellationToken cancellationToken) =>
            coordinator.HandlePairConfirmAsync(request, cancellationToken);
    }

    private sealed class InMemoryPairKeyStorage : IPairKeyStorage
    {
        private readonly Dictionary<Guid, byte[]> _keys = [];
        public void StoreKey(ReadOnlySpan<byte> key, Guid deviceId) => _keys[deviceId] = key.ToArray();
        public byte[]? GetKey(Guid deviceId) => _keys.GetValueOrDefault(deviceId)?.ToArray();
        public void DeleteKey(Guid deviceId) => _keys.Remove(deviceId);
    }

    private sealed class ScriptedPeerTransport(params byte[][] responses) : IPeerTransport
    {
        private readonly Queue<byte[]> _responses = new(responses);

        public Task<byte[]> SendAsync(byte[] data, Peer peer, CancellationToken cancellationToken = default) =>
            Task.FromResult(_responses.Dequeue());
    }

    private sealed class UnusedPeerTransport : IPeerTransport
    {
        public Task<byte[]> SendAsync(byte[] data, Peer peer, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("The hosting side does not send.");
    }
}
