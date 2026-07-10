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

public interface IClipServerBackend
{
    byte[]? GetPairKey(Guid deviceId);
    ReceiveResult Receive(ClipPayload payload);
    Task<PairStartResponse> HandlePairStartAsync(
        PairStartRequest request,
        string remoteHost,
        CancellationToken cancellationToken);
    Task<bool> HandlePairConfirmAsync(
        PairConfirmRequest request,
        CancellationToken cancellationToken);
}

public sealed class ClipServerRouter(DeviceIdentity identity, IClipServerBackend backend)
{
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
                v = 1,
            }, WireJson.Options);
            return JsonResponse(200, body);
        }

        if (request.Path == "/v1/clip")
        {
            try
            {
                var envelope = JsonSerializer.Deserialize<ClipEnvelope>(request.Body, WireJson.Options)
                    ?? throw new JsonException("Missing envelope.");
                var key = backend.GetPairKey(envelope.SourceDeviceId);
                if (key is null)
                {
                    return TextResponse(401, "Unauthorized");
                }

                var payload = EnvelopeCrypto.Open(envelope, key);
                var result = backend.Receive(payload);
                var status = result.Status == ReceiveStatus.Duplicate ? "duplicate" : "ok";
                return JsonResponse(200, Encoding.UTF8.GetBytes($"{{\"status\":\"{status}\"}}"));
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                return TextResponse(400, "Bad Request");
            }
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
                return await backend.HandlePairConfirmAsync(confirmRequest, cancellationToken)
                    ? JsonResponse(200, "{\"status\":\"ok\"}"u8.ToArray())
                    : TextResponse(401, "Unauthorized");
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

    private static HttpResponse JsonResponse(int statusCode, byte[] body) =>
        new(statusCode, new Dictionary<string, string> { ["Content-Type"] = "application/json" }, body);

    private static HttpResponse TextResponse(int statusCode, string body) =>
        new(statusCode, new Dictionary<string, string>(), Encoding.UTF8.GetBytes(body));
}
