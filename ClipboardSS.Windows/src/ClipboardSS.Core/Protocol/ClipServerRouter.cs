using System.Text;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Protocol;

public sealed record PairStartRequest(Guid DeviceId, string DeviceName, string EphemeralPublicKey);
public sealed record PairStartResponse(Guid DeviceId, string DeviceName, string EphemeralPublicKey);
public sealed record PairConfirmRequest(Guid DeviceId, string Proof);

/// <summary>Result of a <c>/v1/pair/confirm</c> request on the hosting (target) side.</summary>
public enum PairConfirmOutcome
{
    Paired,
    Rejected,
    AlreadyPaired,
}

public interface IClipServerBackend
{
    byte[]? GetPairKey(Guid deviceId);
    bool IsConnected(Guid deviceId) => true;
    ReceiveResult Receive(ClipPayload payload);
    /// <param name="sourceDeviceId">The envelope's authenticated sender; it owns the session.</param>
    Task<FileReceiveResult> HandleFileOfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        Task.FromResult(new FileReceiveResult(404, "unsupported"));
    Task<FileReceiveResult> HandleFileChunkAsync(string transferId, int chunkIndex, byte[] body, CancellationToken cancellationToken) =>
        Task.FromResult(new FileReceiveResult(404, "unsupported"));
    Task<FileReceiveResult> HandleFileFinishAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        Task.FromResult(new FileReceiveResult(404, "unsupported"));
    Task<FileReceiveResult> HandleFileCancelAsync(string transferId, Guid sourceDeviceId, CancellationToken cancellationToken) =>
        Task.FromResult(new FileReceiveResult(404, "unsupported"));
    Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken);
    Task<PairConfirmOutcome> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken);
}

/// <param name="replayGuard">
/// Shared by every envelope endpoint; the router is created once per process. Defaults to a new guard.
/// </param>
public sealed class ClipServerRouter(DeviceIdentity identity, IClipServerBackend backend, ReplayGuard? replayGuard = null)
{
    private readonly ReplayGuard _replayGuard = replayGuard ?? new ReplayGuard();

    public async Task<HttpResponse> RouteAsync(
        HttpRequest request,
        string remoteHost,
        CancellationToken cancellationToken = default)
    {
        if (request.Method == "GET" && request.Path == "/v1/id")
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(new
            {
                deviceId = identity.Id,
                deviceName = identity.Name,
                v = WireProtocol.Version,
            }, WireJson.Options);
            return JsonResponse(200, body);
        }

        if (request.Path == "/v1/clip")
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<ClipEnvelope>(request.Body, WireJson.Options)
                    ?? throw new JsonException("Missing envelope.");
                if (envelope.V != WireProtocol.Version) return UpgradeRequiredResponse();
                var key = backend.GetPairKey(envelope.SourceDeviceId);
                if (key is null)
                {
                    return TextResponse(401, "Unauthorized");
                }
                if (!backend.IsConnected(envelope.SourceDeviceId))
                    return TextResponse(401, "Unauthorized");

                var opened = EnvelopeCrypto.OpenStamped<ClipPayload>(envelope, EnvelopePurpose.Clip, identity.Id, key);
                if (ReplayRejection(envelope, opened.SentAt) is { } rejected) return rejected;
                var result = backend.Receive(opened.Payload);
                var status = result.Status == ReceiveStatus.Duplicate ? "duplicate" : "ok";
                return JsonResponse(200, Encoding.UTF8.GetBytes($"{{\"status\":\"{status}\"}}"));
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                return TextResponse(400, "Bad Request");
            }
        }

        if (request.Path == "/v1/file/chunk")
        {
            if (!request.Headers.TryGetValue("x-transfer-id", out var transferId) ||
                !request.Headers.TryGetValue("x-chunk-index", out var indexText) ||
                !int.TryParse(indexText, out var index)) return TextResponse(400, "Bad Request");
            var result = await backend.HandleFileChunkAsync(transferId, index, request.Body, cancellationToken);
            return FileResponse(result);
        }

        if (request.Path is "/v1/file/offer" or "/v1/file/finish" or "/v1/file/cancel")
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<ClipEnvelope>(request.Body, WireJson.Options)
                    ?? throw new JsonException("Missing envelope.");
                if (envelope.V != WireProtocol.Version) return UpgradeRequiredResponse();
                var key = backend.GetPairKey(envelope.SourceDeviceId);
                if (key is null) return TextResponse(401, "Unauthorized");
                if (!backend.IsConnected(envelope.SourceDeviceId)) return TextResponse(401, "Unauthorized");
                FileReceiveResult result;
                if (request.Path == "/v1/file/offer")
                {
                    var offer = EnvelopeCrypto.OpenStamped<FileOfferPayload>(envelope, EnvelopePurpose.FileOffer, identity.Id, key);
                    if (ReplayRejection(envelope, offer.SentAt) is { } rejected) return rejected;
                    result = await backend.HandleFileOfferAsync(offer.Payload, key, envelope.SourceDeviceId, cancellationToken);
                }
                else if (request.Path == "/v1/file/finish")
                {
                    var finish = EnvelopeCrypto.OpenStamped<FileFinishPayload>(envelope, EnvelopePurpose.FileFinish, identity.Id, key);
                    if (ReplayRejection(envelope, finish.SentAt) is { } rejected) return rejected;
                    result = await backend.HandleFileFinishAsync(finish.Payload.TransferId, envelope.SourceDeviceId, cancellationToken);
                }
                else
                {
                    var cancel = EnvelopeCrypto.OpenStamped<FileCancelPayload>(envelope, EnvelopePurpose.FileCancel, identity.Id, key);
                    if (ReplayRejection(envelope, cancel.SentAt) is { } rejected) return rejected;
                    result = await backend.HandleFileCancelAsync(cancel.Payload.TransferId, envelope.SourceDeviceId, cancellationToken);
                }
                return FileResponse(result);
            }
            // AEAD (or inner-JSON) failure: same 401 as Swift and Dart.
            catch (EnvelopeCryptoException) { return TextResponse(401, "Unauthorized"); }
            catch (Exception) when (!cancellationToken.IsCancellationRequested) { return TextResponse(400, "Bad Request"); }
        }

        if (request.Path == "/v1/pair/start")
        {
            try
            {
                var pairRequest = JsonSerializer.Deserialize<PairStartRequest>(request.Body, WireJson.Options)
                    ?? throw new JsonException("Missing pair request.");
                var response = await backend.HandlePairStartAsync(
                    pairRequest,
                    remoteHost,
                    cancellationToken);
                return JsonResponse(200, JsonSerializer.SerializeToUtf8Bytes(response, WireJson.Options));
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                return TextResponse(403, "Rejected");
            }
        }

        if (request.Path == "/v1/pair/confirm")
        {
            try
            {
                var confirmRequest = JsonSerializer.Deserialize<PairConfirmRequest>(request.Body, WireJson.Options)
                    ?? throw new JsonException("Missing confirm request.");
                return await backend.HandlePairConfirmAsync(confirmRequest, cancellationToken) switch
                {
                    PairConfirmOutcome.Paired => JsonResponse(200, "{\"status\":\"ok\"}"u8.ToArray()),
                    PairConfirmOutcome.AlreadyPaired => JsonResponse(409, "{\"status\":\"alreadyPaired\"}"u8.ToArray()),
                    _ => TextResponse(401, "Unauthorized"),
                };
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                return TextResponse(400, "Bad Request");
            }
        }

        return TextResponse(404, "Not Found");
    }

    public static string BonjourSafeTxtValue(string value) => new(value
        .Replace('\u2019', '\'')
        .Replace('\u2018', '\'')
        .Replace('\u201c', '"')
        .Replace('\u201d', '"')
        .Where(character => character <= 0x7f)
        .ToArray());

    /// <summary>
    /// Runs only after a successful AEAD open, before any side effect: 400 stale or 409 replayed,
    /// or null when the envelope may proceed.
    /// </summary>
    private HttpResponse? ReplayRejection(ClipEnvelope envelope, DateTimeOffset sentAt) =>
        _replayGuard.Check(envelope.SourceDeviceId, envelope.Nonce, sentAt) switch
        {
            ReplayCheck.Stale => JsonResponse(400, "{\"status\":\"stale\"}"u8.ToArray()),
            ReplayCheck.Replayed => JsonResponse(409, "{\"status\":\"replayed\"}"u8.ToArray()),
            _ => null,
        };

    /// <summary>426 for an envelope whose <c>v</c> is not <see cref="WireProtocol.Version"/>.</summary>
    private static HttpResponse UpgradeRequiredResponse() =>
        JsonResponse(426, Encoding.UTF8.GetBytes(
            $"{{\"status\":\"upgradeRequired\",\"minVersion\":{WireProtocol.Version}}}"));

    private static HttpResponse JsonResponse(int statusCode, byte[] body) =>
        new(statusCode, new Dictionary<string, string> { ["Content-Type"] = "application/json" }, body);

    private static HttpResponse TextResponse(int statusCode, string body) =>
        new(statusCode, new Dictionary<string, string>(), Encoding.UTF8.GetBytes(body));

    private static HttpResponse FileResponse(FileReceiveResult result)
    {
        var body = new Dictionary<string, object> { ["status"] = result.Status };
        if (result.Received is int received) body["received"] = received;
        return JsonResponse(result.StatusCode, JsonSerializer.SerializeToUtf8Bytes(body, WireJson.Options));
    }
}
