using System.Collections.Concurrent;
using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Sync;

public sealed record ClipSendResult(
    int VisiblePeerCount,
    int PairedPeerCount,
    int SuccessCount,
    int FailureCount)
{
    public bool HasVisiblePeers => VisiblePeerCount > 0;
    public bool HasPairedTargets => PairedPeerCount > 0;
}

public sealed class ClipSender(
    DeviceIdentity identity,
    PairedDeviceStore pairedStore,
    IPeerTransport transport,
    string storageDirectory)
{
    public async Task<ClipSendResult> BroadcastAsync(
        ClipItem clip,
        IEnumerable<Peer> peers,
        CancellationToken cancellationToken = default)
    {
        var targets = peers.Where(peer => peer.Id != identity.Id).ToArray();
        if (targets.Length == 0)
        {
            return new ClipSendResult(0, 0, 0, 0);
        }

        var pairedTargets = targets
            .Select(peer => (Peer: peer, Key: pairedStore.GetKey(peer.Id)))
            .Where(target => target.Key is not null)
            .Select(target => (target.Peer, Key: target.Key!))
            .ToArray();
        if (pairedTargets.Length == 0)
        {
            return new ClipSendResult(targets.Length, 0, 0, 0);
        }

        string? imageBase64 = null;
        string? imageExtension = null;
        if (clip.Type == ClipType.Image && clip.ImagePath is not null)
        {
            var path = Path.Combine(storageDirectory, clip.ImagePath);
            imageBase64 = Convert.ToBase64String(await File.ReadAllBytesAsync(path, cancellationToken));
            imageExtension = Path.GetExtension(path).TrimStart('.');
        }

        var payload = new ClipPayload
        {
            Id = clip.Id,
            Type = clip.Type,
            CreatedAt = clip.CreatedAt,
            Text = clip.Text,
            ImageBase64 = imageBase64,
            ImageExtension = imageExtension,
            PreviewText = clip.PreviewText,
            ContentHash = clip.ContentHash,
            SourceDeviceName = identity.Name,
        };

        var failures = new ConcurrentBag<Exception>();
        await Task.WhenAll(pairedTargets.Select(async target =>
        {
            try
            {
                var envelope = EnvelopeCrypto.Seal(payload, identity.Id, target.Key);
                var envelopeData = JsonSerializer.SerializeToUtf8Bytes(envelope, WireJson.Options);
                var request = new HttpRequest(
                    "POST",
                    "/v1/clip",
                    new Dictionary<string, string> { ["Content-Type"] = "application/json" },
                    envelopeData);
                var responseData = await transport.SendAsync(
                    HttpCodec.EncodeRequest(request, $"{target.Peer.Host}:{target.Peer.Port}"),
                    target.Peer,
                    cancellationToken);
                var response = HttpCodec.ParseResponse(responseData);
                if (response.StatusCode != 200)
                {
                    throw new HttpRequestException(
                        $"Peer returned HTTP {response.StatusCode}.",
                        null,
                        (System.Net.HttpStatusCode)response.StatusCode);
                }
            }
            catch (Exception exception)
            {
                failures.Add(exception);
            }
        }));

        return new ClipSendResult(
            targets.Length,
            pairedTargets.Length,
            pairedTargets.Length - failures.Count,
            failures.Count);
    }
}
