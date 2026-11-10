using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Security;

namespace ClipboardSS.Core.Crypto;

public class EnvelopeCryptoException(string message, Exception? innerException = null)
    : Exception(message, innerException);

/// <summary>The envelope's <c>v</c> is not <see cref="WireProtocol.Version"/>; servers answer 426.</summary>
public sealed class UnsupportedEnvelopeVersionException(int version)
    : EnvelopeCryptoException($"Unsupported envelope version {version}.")
{
    public int Version { get; } = version;
}

/// <summary>
/// What an envelope is for. Bound into the AEAD associated data so an envelope sealed for
/// one endpoint cannot be replayed against another.
/// </summary>
public enum EnvelopePurpose
{
    Clip,
    FileOffer,
    FileFinish,
    FileCancel,
}

public static class EnvelopePurposeExtensions
{
    /// <summary>Value used in the associated data.</summary>
    public static string WireName(this EnvelopePurpose purpose) => purpose switch
    {
        EnvelopePurpose.Clip => "clip",
        EnvelopePurpose.FileOffer => "file-offer",
        EnvelopePurpose.FileFinish => "file-finish",
        EnvelopePurpose.FileCancel => "file-cancel",
        _ => throw new ArgumentOutOfRangeException(nameof(purpose), purpose, null),
    };
}

/// <summary>
/// Wire envelope v2: ChaCha20-Poly1305 over the inner JSON with associated data
/// <c>ClipboardSS/2|&lt;purpose&gt;|&lt;source lowercase&gt;|&lt;recipient lowercase&gt;</c>,
/// binding sender, recipient and purpose. See docs/wire-protocol.md.
/// </summary>
public static class EnvelopeCrypto
{
    public static byte[] AssociatedData(EnvelopePurpose purpose, Guid sourceDeviceId, Guid recipientDeviceId) =>
        Encoding.UTF8.GetBytes(
            $"ClipboardSS/{WireProtocol.Version}|{purpose.WireName()}|" +
            $"{sourceDeviceId.ToString("D").ToLowerInvariant()}|{recipientDeviceId.ToString("D").ToLowerInvariant()}");

    /// <summary>Wire format of <c>sentAt</c> (and every other wire timestamp): whole-second UTC.</summary>
    public const string WireTimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'";

    public static ClipEnvelope Seal(
        ClipPayload payload, EnvelopePurpose purpose, Guid sourceDeviceId, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey,
        DateTimeOffset? sentAt = null)
        => SealJson(payload, purpose, sourceDeviceId, recipientDeviceId, pairKey, sentAt);

    /// <summary>
    /// Seals <paramref name="payload"/> with <c>sentAt</c> (default: now) stamped into the inner JSON,
    /// so the receiver's <see cref="Protocol.ReplayGuard"/> checks freshness on an authenticated value.
    /// </summary>
    public static ClipEnvelope SealJson<T>(
        T payload, EnvelopePurpose purpose, Guid sourceDeviceId, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey,
        DateTimeOffset? sentAt = null)
    {
        var json = JsonSerializer.SerializeToNode(payload, WireJson.Options) as JsonObject
            ?? throw new EnvelopeCryptoException("Envelope payloads must be JSON objects.");
        json["sentAt"] = (sentAt ?? DateTimeOffset.UtcNow).UtcDateTime.ToString(WireTimestampFormat, CultureInfo.InvariantCulture);
        return SealPlaintext(
            JsonSerializer.SerializeToUtf8Bytes(json, WireJson.Options),
            purpose, sourceDeviceId, recipientDeviceId, pairKey);
    }

    /// <summary>Seals raw inner bytes. <paramref name="nonce"/> is injectable only to reproduce the pinned vector.</summary>
    public static ClipEnvelope SealPlaintext(
        byte[] plaintext,
        EnvelopePurpose purpose,
        Guid sourceDeviceId,
        Guid recipientDeviceId,
        ReadOnlySpan<byte> pairKey,
        byte[]? nonce = null)
    {
        if (nonce is null)
        {
            nonce = new byte[12];
            new SecureRandom().NextBytes(nonce);
        }
        var ciphertext = ChaCha20Poly1305Cipher.Encrypt(
            pairKey, nonce, plaintext, AssociatedData(purpose, sourceDeviceId, recipientDeviceId));
        return new ClipEnvelope
        {
            V = WireProtocol.Version,
            SourceDeviceId = sourceDeviceId,
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(ciphertext),
        };
    }

    public static ClipPayload Open(
        ClipEnvelope envelope, EnvelopePurpose purpose, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey)
        => OpenJson<ClipPayload>(envelope, purpose, recipientDeviceId, pairKey);

    /// <summary>Opens an envelope addressed to <paramref name="recipientDeviceId"/> (the local device).</summary>
    public static T OpenJson<T>(
        ClipEnvelope envelope, EnvelopePurpose purpose, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey)
    {
        var plaintext = OpenPlaintext(envelope, purpose, recipientDeviceId, pairKey);
        try
        {
            return JsonSerializer.Deserialize<T>(plaintext, WireJson.Options)
                ?? throw new EnvelopeCryptoException("The envelope payload is empty.");
        }
        catch (JsonException exception)
        {
            throw new EnvelopeCryptoException("The envelope could not be decrypted.", exception);
        }
    }

    /// <summary>
    /// Opens like <see cref="OpenJson{T}"/>, also returning the authenticated <c>sentAt</c>.
    /// A payload without a parsable <c>sentAt</c> opens with <see cref="DateTimeOffset.MinValue"/>,
    /// which the replay guard rejects as stale.
    /// </summary>
    public static OpenedEnvelope<T> OpenStamped<T>(
        ClipEnvelope envelope, EnvelopePurpose purpose, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey)
    {
        var plaintext = OpenPlaintext(envelope, purpose, recipientDeviceId, pairKey);
        try
        {
            using var document = JsonDocument.Parse(plaintext);
            var payload = document.RootElement.Deserialize<T>(WireJson.Options)
                ?? throw new EnvelopeCryptoException("The envelope payload is empty.");
            var sentAt = DateTimeOffset.MinValue;
            if (document.RootElement.TryGetProperty("sentAt", out var element) &&
                element.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(
                    element.GetString(),
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out var parsed))
            {
                sentAt = parsed;
            }
            return new OpenedEnvelope<T>(payload, sentAt);
        }
        catch (JsonException exception)
        {
            throw new EnvelopeCryptoException("The envelope could not be decrypted.", exception);
        }
    }

    public static byte[] OpenPlaintext(
        ClipEnvelope envelope, EnvelopePurpose purpose, Guid recipientDeviceId, ReadOnlySpan<byte> pairKey)
    {
        if (envelope.V != WireProtocol.Version)
        {
            throw new UnsupportedEnvelopeVersionException(envelope.V);
        }
        try
        {
            var nonce = Convert.FromBase64String(envelope.Nonce);
            var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
            if (nonce.Length != 12 || ciphertext.Length < 16)
            {
                throw new EnvelopeCryptoException("The envelope nonce or ciphertext is malformed.");
            }

            return ChaCha20Poly1305Cipher.Decrypt(
                pairKey, nonce, ciphertext,
                AssociatedData(purpose, envelope.SourceDeviceId, recipientDeviceId));
        }
        catch (Exception exception) when (
            exception is InvalidCipherTextException
                or FormatException
                or ArgumentException)
        {
            throw new EnvelopeCryptoException("The envelope could not be decrypted.", exception);
        }
    }
}

/// <summary>An opened envelope's payload plus its authenticated <c>sentAt</c>.</summary>
public sealed record OpenedEnvelope<T>(T Payload, DateTimeOffset SentAt);
