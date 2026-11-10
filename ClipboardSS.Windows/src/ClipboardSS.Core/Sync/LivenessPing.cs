using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;

namespace ClipboardSS.Core.Sync;

/// <summary>What one <c>POST /v1/ping</c> to one host proved. See docs/wire-protocol.md ("Liveness Ping").</summary>
public enum PingOutcome
{
    /// <summary>No evidence either way: unreachable, or not a valid, fresh pong from the expected device for this ping.</summary>
    Unverified,
    /// <summary>A valid pong from the expected device: it is online at the pinged host and speaks v2.</summary>
    Alive,
    /// <summary>The host answered 426: it speaks another protocol version.</summary>
    UpgradeRequired,
    /// <summary>
    /// The host answered <c>400 {"status":"stale"}</c>: its clock disagrees with ours by more than the
    /// freshness window. Unauthenticated, so it never proves liveness.
    /// </summary>
    ClockSkew,
}

/// <summary>Inner payload of a <c>ping</c> envelope: only the <c>sentAt</c> the seal helpers stamp.</summary>
public sealed record PingPayload;

/// <summary>Inner payload of a <c>pong</c>: echoes the ping's nonce so a captured pong cannot answer a later ping.</summary>
public sealed record PongPayload(string PingNonce);

/// <summary>Authenticated liveness: the only evidence that a paired device is online at a host.</summary>
public static class LivenessPing
{
    public const string Path = "/v1/ping";

    /// <summary>
    /// Pings <paramref name="deviceId"/> at <paramref name="host"/> and validates the pong.
    /// <paramref name="send"/> delivers the encoded HTTP request to that host and returns the raw response.
    /// </summary>
    public static async Task<PingOutcome> PingAsync(
        string host,
        Guid deviceId,
        Guid localDeviceId,
        byte[] pairKey,
        Func<byte[], CancellationToken, Task<byte[]>> send,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var envelope = EnvelopeCrypto.SealJson(new PingPayload(), EnvelopePurpose.Ping, localDeviceId, deviceId, pairKey, now);
            var request = new HttpRequest(
                "POST", Path,
                new Dictionary<string, string> { ["Content-Type"] = "application/json" },
                JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options));
            var response = HttpCodec.ParseResponse(
                await send(HttpCodec.EncodeRequest(request, $"{host}:51888"), cancellationToken));
            return EvaluatePong(response.StatusCode, response.Body, envelope.Nonce, deviceId, localDeviceId, pairKey, now);
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            return PingOutcome.Unverified;
        }
    }

    /// <summary>
    /// Caller-side validation: 200, a v2 <c>pong</c> envelope from <paramref name="deviceId"/> sealed to us,
    /// fresh within the replay window, echoing this ping's nonce.
    /// </summary>
    public static PingOutcome EvaluatePong(
        int statusCode,
        byte[] body,
        string pingNonce,
        Guid deviceId,
        Guid localDeviceId,
        byte[] pairKey,
        DateTimeOffset? now = null)
    {
        if (statusCode == 426) return PingOutcome.UpgradeRequired;
        if (statusCode == 400 && ResponseStatus(body) == "stale") return PingOutcome.ClockSkew;
        if (statusCode != 200) return PingOutcome.Unverified;
        try
        {
            var envelope = JsonSerializer.Deserialize<ClipEnvelope>(body, WireJson.Options);
            if (envelope is null || envelope.SourceDeviceId != deviceId) return PingOutcome.Unverified;
            var opened = EnvelopeCrypto.OpenStamped<PongPayload>(envelope, EnvelopePurpose.Pong, localDeviceId, pairKey);
            if ((now ?? DateTimeOffset.UtcNow) - opened.SentAt is var skew && skew.Duration() > ReplayGuard.DefaultWindow)
                return PingOutcome.Unverified;
            return Convert.FromBase64String(opened.Payload.PingNonce).AsSpan()
                .SequenceEqual(Convert.FromBase64String(pingNonce))
                ? PingOutcome.Alive
                : PingOutcome.Unverified;
        }
        catch (Exception exception) when (exception is JsonException or EnvelopeCryptoException or FormatException or ArgumentException)
        {
            return PingOutcome.Unverified;
        }
    }

    private static string? ResponseStatus(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("status", out var status) &&
                status.ValueKind == JsonValueKind.String
                ? status.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// Responder side of <c>POST /v1/ping</c>: version → pairing → AEAD open → replay guard →
    /// pong sealed back to the caller. The local pause switch is not consulted: liveness reports
    /// reachability, and pausing only refuses content.
    /// </summary>
    public static (int StatusCode, byte[] Body) Respond(
        ClipEnvelope envelope,
        Guid localDeviceId,
        Func<Guid, byte[]?> getPairKey,
        ReplayGuard replayGuard)
    {
        if (envelope.V != WireProtocol.Version)
            return (426, System.Text.Encoding.UTF8.GetBytes(
                $"{{\"status\":\"upgradeRequired\",\"minVersion\":{WireProtocol.Version}}}"));
        var key = getPairKey(envelope.SourceDeviceId);
        if (key is null) return (401, "{\"status\":\"unauthorized\"}"u8.ToArray());
        OpenedEnvelope<PingPayload> opened;
        try
        {
            opened = EnvelopeCrypto.OpenStamped<PingPayload>(envelope, EnvelopePurpose.Ping, localDeviceId, key);
        }
        catch (EnvelopeCryptoException)
        {
            return (401, "{\"status\":\"unauthorized\"}"u8.ToArray());
        }
        switch (replayGuard.Check(envelope.SourceDeviceId, envelope.Nonce, opened.SentAt))
        {
            case ReplayCheck.Stale: return (400, "{\"status\":\"stale\"}"u8.ToArray());
            case ReplayCheck.Replayed: return (409, "{\"status\":\"replayed\"}"u8.ToArray());
        }
        var pong = EnvelopeCrypto.SealJson(
            new PongPayload(envelope.Nonce), EnvelopePurpose.Pong, localDeviceId, envelope.SourceDeviceId, key);
        return (200, JsonSerializer.SerializeToUtf8Bytes(pong, WireJson.Options));
    }
}
