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
    private DateTimeOffset _now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    public PairingCoordinatorTests()
    {
        _store = new PairedDeviceStore(Path.Combine(_directory.Path, "paired-devices.json"), new InMemoryPairKeyStorage());
        _coordinator = new PairingCoordinator(_identity, _store, new UnusedPeerTransport(), () => _now);
    }

    public void Dispose() => _directory.Dispose();

    [Fact]
    public async Task ConfirmWithWrongProofInvalidatesCode()
    {
        var code = _coordinator.StartHosting();
        var initiation = await StartAsync(InitiatorA, code);

        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, new byte[32]));

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
        Assert.Equal(PairConfirmOutcome.Paired, await ConfirmAsync(InitiatorA, first.Proof));
        Assert.Equal(first.PairKey, _store.GetKey(InitiatorA));
    }

    [Fact]
    public async Task SecondStartFromSameInitiatorReplacesPending()
    {
        var code = _coordinator.StartHosting();
        await StartAsync(InitiatorA, code);
        var second = await StartAsync(InitiatorA, code);

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

        // The stale initiator no longer occupies the new code...
        await StartAsync(InitiatorB, newCode);

        // ...and its old proof cannot complete pairing.
        Assert.Equal(PairConfirmOutcome.Rejected, await ConfirmAsync(InitiatorA, stale.Proof));
        Assert.Null(_store.GetKey(InitiatorA));
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
            HttpCodec.EncodeResponse(new HttpResponse(409, json, Encoding.UTF8.GetBytes("{\"status\":\"alreadyPaired\"}"))));
        var initiator = new PairingCoordinator(_identity, _store, transport, () => _now);

        var exception = await Assert.ThrowsAsync<PairingAlreadyPairedException>(() =>
            initiator.StartPairingAsync(new Peer(target.Id, target.Name, "10.0.0.2", 51888), "123456", TestContext.Current.CancellationToken));
        Assert.Equal("Remove the existing pairing on the other device first", exception.Message);
        Assert.Empty(_store.Devices);
    }

    /// <summary>Plays the initiator side of <c>/v1/pair/start</c> and derives the proof it would confirm with.</summary>
    private async Task<(byte[] PairKey, byte[] Proof)> StartAsync(Guid initiatorId, string code)
    {
        var session = new PairingSession();
        var response = await _coordinator.HandlePairStartAsync(
            new PairStartRequest(initiatorId, "Initiator", Convert.ToBase64String(session.EphemeralPublicKey)),
            "10.0.0.9",
            TestContext.Current.CancellationToken);
        var result = session.CompletePairing(
            Convert.FromBase64String(response.EphemeralPublicKey),
            initiatorId,
            _identity.Id,
            true,
            code);
        return (result.PairKey, PairingSession.GenerateConfirmationProof(result.PairKey, initiatorId, _identity.Id));
    }

    private Task<PairConfirmOutcome> ConfirmAsync(Guid initiatorId, byte[] proof) =>
        _coordinator.HandlePairConfirmAsync(
            new PairConfirmRequest(initiatorId, Convert.ToBase64String(proof)),
            TestContext.Current.CancellationToken);

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
