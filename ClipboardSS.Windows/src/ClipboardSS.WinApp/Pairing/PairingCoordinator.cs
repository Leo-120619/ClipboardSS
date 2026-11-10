using System.Security.Cryptography;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Pairing;

/// <summary>A <c>/v1/pair/start</c> that must be refused (HTTP 403): no active code, another initiator is pending, or a bad commitment.</summary>
public sealed class PairingRejectedException(string message) : InvalidOperationException(message);

/// <summary>The target answered 409: it already has this device paired, so it must be removed there first.</summary>
public sealed class PairingAlreadyPairedException()
    : InvalidOperationException("Remove the existing pairing on the other device first");

/// <summary>The other device refused (403 / 401 / 400): wrong code, numbers not confirmed there, or cancelled.</summary>
public sealed class PairingNotAcceptedException(int statusCode)
    : InvalidOperationException("The other device did not accept. Check the code, or show a new one, and try again.")
{
    public int StatusCode { get; } = statusCode;
}

/// <summary>The other device's user did not confirm the number within 60 s (408).</summary>
public sealed class PairingTimedOutException()
    : InvalidOperationException("The other device did not confirm in time. Show a new code and try again.");

/// <summary>The number both screens show during pairing, with the other device's name.</summary>
/// <param name="LocalConfirmed">This device's user already pressed Confirm and is waiting for the other side.</param>
public sealed record PairingComparison(string DeviceName, string ConfirmCode, bool LocalConfirmed = false);

/// <param name="confirmTransport">
/// Used for <c>/v1/pair/confirm</c>, which the target may hold for <see cref="DefaultConfirmHoldTimeout"/>;
/// give it a timeout of at least <see cref="DefaultConfirmRequestTimeout"/>.
/// </param>
public sealed class PairingCoordinator(
    DeviceIdentity identity,
    PairedDeviceStore pairedStore,
    IPeerTransport transport,
    Func<DateTimeOffset>? clock = null,
    IPeerTransport? confirmTransport = null,
    TimeSpan? confirmHoldTimeout = null)
{
    /// <summary>How long the target holds <c>/v1/pair/confirm</c> waiting for its own user (else 408).</summary>
    public static readonly TimeSpan DefaultConfirmHoldTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Client timeout for <c>/v1/pair/confirm</c>: longer than the target's hold.</summary>
    public static readonly TimeSpan DefaultConfirmRequestTimeout = TimeSpan.FromSeconds(75);

    private readonly Func<DateTimeOffset> _now = clock ?? (() => DateTimeOffset.UtcNow);
    private readonly IPeerTransport _confirmTransport = confirmTransport ?? transport;
    private readonly TimeSpan _confirmHoldTimeout = confirmHoldTimeout ?? DefaultConfirmHoldTimeout;
    private readonly object _gate = new();

    // Hosting state, guarded by _gate. All pairing rules on the target side are enforced in
    // HandlePairStartAsync / HandlePairRevealAsync / HandlePairConfirmAsync below:
    // - one pending initiator per code (the same deviceId may restart until it has revealed;
    //   any other start is refused with 403);
    // - reveal and confirm are refused (401) unless the code is active and unexpired;
    // - any failure (bad reveal or commitment, bad proof, cancel here, 60 s confirm timeout)
    //   ends the code and clears pending state; so do stop, expiry and start;
    // - every confirm spends the code; an already paired deviceId gets 409;
    // - keys are stored only after both users confirmed the number;
    // - commitment and proof checks are constant-time; codes, numbers and keys are never logged.
    private PendingInitiator? _pending;
    private HeldConfirm? _held;
    private string? _hostCode;
    private DateTimeOffset? _hostCodeExpiry;
    private Timer? _expiryTimer;
    private PairingComparison? _hostComparison;
    /// <summary>Bumped whenever hosting ends or restarts, so work done outside the lock can tell whether its state is current.</summary>
    private int _generation;

    // Initiator state, guarded by _gate: the one device the user chose.
    private PendingJoin? _pendingJoin;
    private PairingComparison? _joinComparison;

    public DeviceIdentity Identity { get; } = identity;
    public PairedDeviceStore PairedStore { get; } = pairedStore;
    public bool IsPairing { get; private set; }
    public event EventHandler? PairedDevicesChanged;

    /// <summary>
    /// Raised (on any thread) whenever the pairing state shown to the user changes: the hosted code
    /// ends (spent by any failure, expired, stopped), or a number to compare appears, changes or goes away.
    /// </summary>
    public event EventHandler? HostingChanged;

    /// <summary>The hosted code while it is active and unexpired.</summary>
    public string? HostCode
    {
        get
        {
            bool ended;
            string? code;
            lock (_gate) code = ActiveHostCode(out ended);
            if (ended) RaiseHostingChanged();
            return code;
        }
    }

    /// <summary>The number to compare while this device is the target.</summary>
    public PairingComparison? HostComparison { get { lock (_gate) return _hostComparison; } }

    /// <summary>The number to compare while this device is the initiator.</summary>
    public PairingComparison? JoinComparison { get { lock (_gate) return _joinComparison; } }

    /// <summary>True while a <c>/v1/pair/confirm</c> is waiting for this device's user.</summary>
    internal bool IsHoldingConfirm { get { lock (_gate) return _held is not null; } }

    // Target

    public string StartHosting(TimeSpan? ttl = null)
    {
        var lifetime = ttl ?? TimeSpan.FromSeconds(180);
        string code;
        lock (_gate)
        {
            EndHosting();
            code = RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
            _hostCode = code;
            _hostCodeExpiry = _now() + lifetime;
            // Clears the code from the UI when it expires, without waiting for a request.
            _expiryTimer = new Timer(_ => _ = HostCode, null, lifetime, Timeout.InfiniteTimeSpan);
        }
        RaiseHostingChanged();
        return code;
    }

    public void StopHosting()
    {
        lock (_gate) EndHosting();
        RaiseHostingChanged();
    }

    /// <summary>This device's user confirmed the number shown in <see cref="HostComparison"/>.</summary>
    public void ConfirmHostedPairing()
    {
        lock (_gate)
        {
            if (_held is { } held)
            {
                ResolveHeld(held, HostDecision.Confirmed);
            }
            else if (_hostComparison is not null)
            {
                _hostComparison = _hostComparison with { LocalConfirmed = true };
            }
            else
            {
                return;
            }
        }
        RaiseHostingChanged();
    }

    /// <summary>This device's user cancelled (or the numbers differ): the code is spent.</summary>
    public void CancelHostedPairing() => StopHosting();

    public Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        byte[] commitment;
        try
        {
            commitment = Convert.FromBase64String(request.Commitment);
        }
        catch (FormatException)
        {
            throw new PairingRejectedException("The commitment is malformed.");
        }
        if (commitment.Length != 32) throw new PairingRejectedException("The commitment is malformed.");

        var session = new PairingSession();
        bool ended;
        string? code;
        lock (_gate)
        {
            code = ActiveHostCode(out ended);
            if (code is not null)
            {
                if (_pending is not null && (_pending.Id != request.DeviceId || _pending.PairKey is not null))
                {
                    throw new PairingRejectedException("Another device is already pairing with this code.");
                }
                _pending = new PendingInitiator(request.DeviceId, request.DeviceName, remoteHost, commitment, session);
            }
        }
        if (ended) RaiseHostingChanged();
        if (code is null) throw new PairingRejectedException("This device is not hosting a pairing code.");

        return Task.FromResult(new PairStartResponse(
            Identity.Id,
            Identity.Name,
            Convert.ToBase64String(session.EphemeralPublicKey)));
    }

    public Task<PairRevealOutcome> HandlePairRevealAsync(
        PairRevealRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PairRevealOutcome outcome;
        lock (_gate) outcome = Reveal(request);
        RaiseHostingChanged();
        return Task.FromResult(outcome);
    }

    /// <summary>Call under _gate.</summary>
    private PairRevealOutcome Reveal(PairRevealRequest request)
    {
        var code = ActiveHostCode(out _);
        if (code is null) return PairRevealOutcome.Rejected;
        var pending = _pending;
        if (pending is null || pending.Id != request.DeviceId || pending.PairKey is not null)
        {
            EndHosting();
            return PairRevealOutcome.Rejected;
        }

        PairingResult? result = null;
        try
        {
            var publicKey = Convert.FromBase64String(request.EphemeralPublicKey);
            var salt = Convert.FromBase64String(request.Salt);
            if (salt.Length == PairingSession.SaltLength &&
                PairingSession.CommitmentMatches(pending.Commitment, publicKey, salt))
            {
                result = pending.Session.CompletePairing(publicKey, false, code);
            }
        }
        catch (Exception exception) when (exception is FormatException or PairingException)
        {
            result = null;
        }

        if (result is null)
        {
            EndHosting();
            return PairRevealOutcome.Invalid;
        }
        pending.PairKey = result.PairKey;
        _hostComparison = new PairingComparison(pending.Name, result.ConfirmCode);
        return PairRevealOutcome.Ok;
    }

    public async Task<PairConfirmOutcome> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PendingInitiator? pending = null;
        var localConfirmed = false;
        var generation = 0;
        bool ended;
        bool active;
        lock (_gate)
        {
            active = ActiveHostCode(out ended) is not null;
            if (active)
            {
                // Every confirm spends the code; the comparison stays on screen until it is resolved.
                pending = _pending;
                localConfirmed = _hostComparison?.LocalConfirmed == true;
                _pending = null;
                _hostCode = null;
                _hostCodeExpiry = null;
                _expiryTimer?.Dispose();
                _expiryTimer = null;
                generation = _generation;
            }
        }
        if (ended) RaiseHostingChanged();
        if (!active) return PairConfirmOutcome.Rejected;

        if (!IsValidProof(pending, request))
        {
            EndHostingIfCurrent(generation);
            return PairConfirmOutcome.Rejected;
        }

        if (PairedStore.Devices.Any(device => device.Id == request.DeviceId))
        {
            EndHostingIfCurrent(generation);
            return PairConfirmOutcome.AlreadyPaired;
        }

        if (!localConfirmed)
        {
            var decision = await HoldForLocalDecisionAsync(generation).ConfigureAwait(false);
            if (decision != HostDecision.Confirmed)
            {
                EndHostingIfCurrent(generation);
                return decision == HostDecision.TimedOut ? PairConfirmOutcome.TimedOut : PairConfirmOutcome.Rejected;
            }
        }
        EndHostingIfCurrent(generation);

        PairedStore.AddDevice(new PairedDevice(request.DeviceId, pending!.Name, pending.Host), pending.PairKey!);
        PairedDevicesChanged?.Invoke(this, EventArgs.Empty);
        return PairConfirmOutcome.Paired;
    }

    private async Task<HostDecision> HoldForLocalDecisionAsync(int generation)
    {
        var decision = new TaskCompletionSource<HostDecision>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var timeout = new CancellationTokenSource();
        var held = new HeldConfirm(decision);
        lock (_gate)
        {
            if (generation != _generation) return HostDecision.Cancelled;
            _held = held;
        }
        using var registration = timeout.Token.Register(() =>
        {
            lock (_gate)
            {
                if (ReferenceEquals(_held, held)) ResolveHeld(held, HostDecision.TimedOut);
            }
        });
        timeout.CancelAfter(_confirmHoldTimeout);
        RaiseHostingChanged();
        return await decision.Task.ConfigureAwait(false);
    }

    private bool IsValidProof(PendingInitiator? pending, PairConfirmRequest request)
    {
        if (pending is null || pending.Id != request.DeviceId || pending.PairKey is null) return false;
        try
        {
            return PairingSession.VerifyConfirmationProof(
                Convert.FromBase64String(request.Proof),
                pending.PairKey,
                request.DeviceId,
                Identity.Id);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    // Initiator

    /// <summary>
    /// Runs <c>/v1/pair/start</c> and <c>/v1/pair/reveal</c> against the one device the user chose and
    /// returns the number to compare. Nothing is stored until <see cref="ConfirmPairingAsync"/> succeeds.
    /// </summary>
    public async Task<PairingComparison> StartPairingAsync(
        Peer peer,
        string code,
        CancellationToken cancellationToken = default)
    {
        if (code.Length != 6 || code.Any(character => !char.IsAsciiDigit(character)))
        {
            throw new ArgumentException("Enter a 6-digit pairing code.", nameof(code));
        }

        CancelPairing();
        IsPairing = true;
        try
        {
            var session = new PairingSession();
            var salt = PairingSession.RandomSalt();
            var start = await PostAsync(
                peer,
                "/v1/pair/start",
                new PairStartRequest(
                    Identity.Id,
                    Identity.Name,
                    Convert.ToBase64String(PairingSession.Commitment(session.EphemeralPublicKey, salt))),
                transport,
                cancellationToken);
            if (start.StatusCode != 200) throw new PairingNotAcceptedException(start.StatusCode);
            var response = JsonSerializer.Deserialize<PairStartResponse>(start.Body, WireJson.Options)
                ?? throw new JsonException("Pairing endpoint /v1/pair/start returned an empty body.");

            var reveal = await PostAsync(
                peer,
                "/v1/pair/reveal",
                new PairRevealRequest(
                    Identity.Id,
                    Convert.ToBase64String(session.EphemeralPublicKey),
                    Convert.ToBase64String(salt)),
                transport,
                cancellationToken);
            if (reveal.StatusCode != 200) throw new PairingNotAcceptedException(reveal.StatusCode);

            var result = session.CompletePairing(Convert.FromBase64String(response.EphemeralPublicKey), true, code);
            var comparison = new PairingComparison(response.DeviceName, result.ConfirmCode);
            lock (_gate)
            {
                _pendingJoin = new PendingJoin(peer, response.DeviceId, response.DeviceName, result.PairKey);
                _joinComparison = comparison;
            }
            RaiseHostingChanged();
            return comparison;
        }
        finally
        {
            IsPairing = false;
        }
    }

    /// <summary>
    /// This device's user confirmed the number: sends the proof and, once the other device's user
    /// confirmed too (200), stores the pairing.
    /// </summary>
    public async Task ConfirmPairingAsync(CancellationToken cancellationToken = default)
    {
        PendingJoin join;
        lock (_gate)
        {
            join = _pendingJoin ?? throw new InvalidOperationException("No pairing is waiting for confirmation.");
            _joinComparison = _joinComparison is null ? null : _joinComparison with { LocalConfirmed = true };
        }
        RaiseHostingChanged();
        try
        {
            var proof = PairingSession.GenerateConfirmationProof(join.PairKey, Identity.Id, join.TargetId);
            var response = await PostAsync(
                join.Peer,
                "/v1/pair/confirm",
                new PairConfirmRequest(Identity.Id, Convert.ToBase64String(proof)),
                _confirmTransport,
                cancellationToken);
            switch (response.StatusCode)
            {
                case 200:
                    PairedStore.AddDevice(new PairedDevice(join.TargetId, join.TargetName, join.Peer.Host), join.PairKey);
                    PairedDevicesChanged?.Invoke(this, EventArgs.Empty);
                    break;
                case 409:
                    throw new PairingAlreadyPairedException();
                case 408:
                    throw new PairingTimedOutException();
                default:
                    throw new PairingNotAcceptedException(response.StatusCode);
            }
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_pendingJoin, join))
                {
                    _pendingJoin = null;
                    _joinComparison = null;
                }
            }
            RaiseHostingChanged();
        }
    }

    /// <summary>This device's user cancelled (or the numbers differ). Nothing was stored.</summary>
    public void CancelPairing()
    {
        lock (_gate)
        {
            if (_pendingJoin is null && _joinComparison is null) return;
            _pendingJoin = null;
            _joinComparison = null;
        }
        RaiseHostingChanged();
    }

    /// <summary>The hosted code while it is unexpired; an expired code ends hosting. Call under _gate.</summary>
    private string? ActiveHostCode(out bool ended)
    {
        ended = false;
        if (_hostCode is null) return null;
        if (_hostCodeExpiry > _now()) return _hostCode;
        EndHosting();
        ended = true;
        return null;
    }

    /// <summary>Ends the hosted code and all pending state; a held confirm is answered 401. Call under _gate.</summary>
    private void EndHosting()
    {
        _generation++;
        _pending = null;
        _hostCode = null;
        _hostCodeExpiry = null;
        _expiryTimer?.Dispose();
        _expiryTimer = null;
        _hostComparison = null;
        if (_held is { } held) ResolveHeld(held, HostDecision.Cancelled);
    }

    private void EndHostingIfCurrent(int generation)
    {
        lock (_gate)
        {
            if (generation != _generation) return;
            EndHosting();
        }
        RaiseHostingChanged();
    }

    /// <summary>Call under _gate.</summary>
    private void ResolveHeld(HeldConfirm held, HostDecision decision)
    {
        _held = null;
        held.Decision.TrySetResult(decision);
    }

    private void RaiseHostingChanged() => HostingChanged?.Invoke(this, EventArgs.Empty);

    private async Task<HttpResponse> PostAsync(
        Peer peer,
        string path,
        object body,
        IPeerTransport via,
        CancellationToken cancellationToken)
    {
        var request = new HttpRequest(
            "POST",
            path,
            new Dictionary<string, string> { ["Content-Type"] = "application/json" },
            JsonSerializer.SerializeToUtf8Bytes(body, WireJson.Options));
        var responseBytes = await via.SendAsync(
            HttpCodec.EncodeRequest(request, $"{peer.Host}:{peer.Port}"),
            peer,
            cancellationToken).ConfigureAwait(false);
        return HttpCodec.ParseResponse(responseBytes);
    }

    private enum HostDecision { Confirmed, Cancelled, TimedOut }

    /// <summary>The single initiator that has sent <c>/v1/pair/start</c> against the hosted code.</summary>
    private sealed class PendingInitiator(Guid id, string name, string host, byte[] commitment, PairingSession session)
    {
        public Guid Id { get; } = id;
        public string Name { get; } = name;
        public string Host { get; } = host;
        public byte[] Commitment { get; } = commitment;
        public PairingSession Session { get; } = session;
        /// <summary>Set by a valid <c>/v1/pair/reveal</c>.</summary>
        public byte[]? PairKey { get; set; }
    }

    /// <summary>A valid <c>/v1/pair/confirm</c> waiting for this device's user.</summary>
    private sealed class HeldConfirm(TaskCompletionSource<HostDecision> decision)
    {
        public TaskCompletionSource<HostDecision> Decision { get; } = decision;
    }

    private sealed record PendingJoin(Peer Peer, Guid TargetId, string TargetName, byte[] PairKey);
}
