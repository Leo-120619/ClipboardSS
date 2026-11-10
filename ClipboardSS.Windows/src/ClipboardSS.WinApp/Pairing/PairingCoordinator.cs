using System.Security.Cryptography;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Pairing;

public sealed class PairingCoordinator(
    DeviceIdentity identity,
    PairedDeviceStore pairedStore,
    IPeerTransport transport)
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, PendingTarget> _pendingTargets = [];
    private string? _hostCode;
    private DateTimeOffset? _hostCodeExpiry;

    public DeviceIdentity Identity { get; } = identity;
    public PairedDeviceStore PairedStore { get; } = pairedStore;
    public bool IsPairing { get; private set; }
    public event EventHandler? PairedDevicesChanged;

    public string StartHosting(TimeSpan? ttl = null)
    {
        lock (_gate)
        {
            _hostCode = RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
            _hostCodeExpiry = DateTimeOffset.UtcNow + (ttl ?? TimeSpan.FromSeconds(180));
            return _hostCode;
        }
    }

    public void StopHosting()
    {
        lock (_gate)
        {
            _hostCode = null;
            _hostCodeExpiry = null;
            _pendingTargets.Clear();
        }
    }

    public Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var code = ActiveHostCode() ?? throw new InvalidOperationException("This device is not hosting a pairing code.");
        var remotePublicKey = Convert.FromBase64String(request.EphemeralPublicKey);
        var session = new PairingSession();
        var result = session.CompletePairing(
            remotePublicKey,
            request.DeviceId,
            Identity.Id,
            false,
            code);
        lock (_gate)
        {
            _pendingTargets[request.DeviceId] = new PendingTarget(
                result.PairKey,
                request.DeviceName,
                remoteHost);
        }

        return Task.FromResult(new PairStartResponse(
            Identity.Id,
            Identity.Name,
            Convert.ToBase64String(session.EphemeralPublicKey)));
    }

    public Task<bool> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PendingTarget? pending;
        lock (_gate)
        {
            _pendingTargets.TryGetValue(request.DeviceId, out pending);
        }

        if (pending is null) return Task.FromResult(false);
        var proof = Convert.FromBase64String(request.Proof);
        if (!PairingSession.VerifyConfirmationProof(
                proof,
                pending.PairKey,
                request.DeviceId,
                Identity.Id))
        {
            return Task.FromResult(false);
        }

        PairedStore.AddDevice(
            new PairedDevice(request.DeviceId, pending.Name, pending.Host),
            pending.PairKey);
        StopHosting();
        PairedDevicesChanged?.Invoke(this, EventArgs.Empty);
        return Task.FromResult(true);
    }

    public async Task StartPairingAsync(
        Peer peer,
        string code,
        CancellationToken cancellationToken = default)
    {
        if (code.Length != 6 || code.Any(character => !char.IsAsciiDigit(character)))
        {
            throw new ArgumentException("Enter a 6-digit pairing code.", nameof(code));
        }

        IsPairing = true;
        try
        {
            var session = new PairingSession();
            var request = new PairStartRequest(
                Identity.Id,
                Identity.Name,
                Convert.ToBase64String(session.EphemeralPublicKey));
            var response = await SendJsonAsync<PairStartResponse>(
                peer,
                "/v1/pair/start",
                request,
                cancellationToken);
            var targetPublicKey = Convert.FromBase64String(response.EphemeralPublicKey);
            var result = session.CompletePairing(
                targetPublicKey,
                Identity.Id,
                response.DeviceId,
                true,
                code);
            var proof = PairingSession.GenerateConfirmationProof(
                result.PairKey,
                Identity.Id,
                response.DeviceId);
            _ = await SendJsonAsync<JsonElement>(
                peer,
                "/v1/pair/confirm",
                new PairConfirmRequest(Identity.Id, Convert.ToBase64String(proof)),
                cancellationToken);
            PairedStore.AddDevice(
                new PairedDevice(response.DeviceId, response.DeviceName, peer.Host),
                result.PairKey);
            PairedDevicesChanged?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            IsPairing = false;
        }
    }

    private string? ActiveHostCode()
    {
        lock (_gate)
        {
            if (_hostCode is not null && _hostCodeExpiry > DateTimeOffset.UtcNow) return _hostCode;
            _hostCode = null;
            _hostCodeExpiry = null;
            _pendingTargets.Clear();
            return null;
        }
    }

    private async Task<TResponse> SendJsonAsync<TResponse>(
        Peer peer,
        string path,
        object body,
        CancellationToken cancellationToken)
    {
        var request = new HttpRequest(
            "POST",
            path,
            new Dictionary<string, string> { ["Content-Type"] = "application/json" },
            JsonSerializer.SerializeToUtf8Bytes(body, WireJson.Options));
        var responseBytes = await transport.SendAsync(
            HttpCodec.EncodeRequest(request, $"{peer.Host}:{peer.Port}"),
            peer,
            cancellationToken);
        var response = HttpCodec.ParseResponse(responseBytes);
        if (response.StatusCode != 200)
        {
            throw new HttpRequestException(
                $"Pairing endpoint {path} returned HTTP {response.StatusCode}.",
                null,
                (System.Net.HttpStatusCode)response.StatusCode);
        }

        return JsonSerializer.Deserialize<TResponse>(response.Body, WireJson.Options)
            ?? throw new JsonException($"Pairing endpoint {path} returned an empty body.");
    }

    private sealed record PendingTarget(byte[] PairKey, string Name, string Host);
}
