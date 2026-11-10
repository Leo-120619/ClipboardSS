using System.Security.Cryptography;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Pairing;

/// <summary>A <c>/v1/pair/start</c> that must be refused (HTTP 403): no active code, or another initiator is pending.</summary>
public sealed class PairingRejectedException(string message) : InvalidOperationException(message);

/// <summary>The target answered 409: it already has this device paired, so it must be removed there first.</summary>
public sealed class PairingAlreadyPairedException()
    : InvalidOperationException("Remove the existing pairing on the other device first");

public sealed class PairingCoordinator(
    DeviceIdentity identity,
    PairedDeviceStore pairedStore,
    IPeerTransport transport,
    Func<DateTimeOffset>? clock = null)
{
    private readonly Func<DateTimeOffset> _now = clock ?? (() => DateTimeOffset.UtcNow);
    private readonly object _gate = new();

    // Hosting state, guarded by _gate. All pairing rules on the target side are enforced in
    // HandlePairStartAsync / HandlePairConfirmAsync below: one pending initiator per code,
    // confirm only while the code is active, any confirm ends the code, and no silent
    // re-pair of a known deviceId.
    private PendingInitiator? _pending;
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
            _pending = null;
            _hostCode = RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
            _hostCodeExpiry = _now() + (ttl ?? TimeSpan.FromSeconds(180));
            return _hostCode;
        }
    }

    public void StopHosting()
    {
        lock (_gate)
        {
            ClearHosting();
        }
    }

    public Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string code;
        lock (_gate)
        {
            code = ActiveHostCode() ?? throw new PairingRejectedException("This device is not hosting a pairing code.");
            EnsureNoOtherPendingInitiator(request.DeviceId);
        }

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
            // Hosting state may have changed while the key exchange ran outside the lock.
            if (ActiveHostCode() != code) throw new PairingRejectedException("The pairing code is no longer active.");
            EnsureNoOtherPendingInitiator(request.DeviceId);
            _pending = new PendingInitiator(request.DeviceId, result.PairKey, request.DeviceName, remoteHost);
        }

        return Task.FromResult(new PairStartResponse(
            Identity.Id,
            Identity.Name,
            Convert.ToBase64String(session.EphemeralPublicKey)));
    }

    public Task<PairConfirmOutcome> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Every confirm ends the hosted code, whatever its outcome.
        PendingInitiator? pending;
        lock (_gate)
        {
            pending = ActiveHostCode() is null ? null : _pending;
            ClearHosting();
        }

        if (pending is null || pending.Id != request.DeviceId) return Task.FromResult(PairConfirmOutcome.Rejected);
        byte[] proof;
        try
        {
            proof = Convert.FromBase64String(request.Proof);
        }
        catch (FormatException)
        {
            return Task.FromResult(PairConfirmOutcome.Rejected);
        }

        if (!PairingSession.VerifyConfirmationProof(
                proof,
                pending.PairKey,
                request.DeviceId,
                Identity.Id))
        {
            return Task.FromResult(PairConfirmOutcome.Rejected);
        }

        if (PairedStore.Devices.Any(device => device.Id == request.DeviceId))
        {
            return Task.FromResult(PairConfirmOutcome.AlreadyPaired);
        }

        PairedStore.AddDevice(
            new PairedDevice(request.DeviceId, pending.Name, pending.Host),
            pending.PairKey);
        PairedDevicesChanged?.Invoke(this, EventArgs.Empty);
        return Task.FromResult(PairConfirmOutcome.Paired);
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
            try
            {
                _ = await SendJsonAsync<JsonElement>(
                    peer,
                    "/v1/pair/confirm",
                    new PairConfirmRequest(Identity.Id, Convert.ToBase64String(proof)),
                    cancellationToken);
            }
            catch (HttpRequestException exception) when (exception.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
                throw new PairingAlreadyPairedException();
            }
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

    /// <summary>The hosted code while it is unexpired; an expired code is cleared with any pending initiator. Call under _gate.</summary>
    private string? ActiveHostCode()
    {
        if (_hostCode is not null && _hostCodeExpiry > _now()) return _hostCode;
        ClearHosting();
        return null;
    }

    private void EnsureNoOtherPendingInitiator(Guid initiatorId)
    {
        if (_pending is not null && _pending.Id != initiatorId)
        {
            throw new PairingRejectedException("Another device is already pairing with this code.");
        }
    }

    private void ClearHosting()
    {
        _pending = null;
        _hostCode = null;
        _hostCodeExpiry = null;
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

    private sealed record PendingInitiator(Guid Id, byte[] PairKey, string Name, string Host);
}
