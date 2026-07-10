using System.Text.Json;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Security;

namespace ClipboardSS.Core.Crypto;

public sealed class EnvelopeCryptoException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public static class EnvelopeCrypto
{
    public static ClipEnvelope Seal(ClipPayload payload, Guid sourceDeviceId, ReadOnlySpan<byte> pairKey)
    {
        var nonce = new byte[12];
        new SecureRandom().NextBytes(nonce);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(payload, WireJson.Options);
        var ciphertext = ChaCha20Poly1305Cipher.Encrypt(pairKey, nonce, plaintext);
        return new ClipEnvelope
        {
            SourceDeviceId = sourceDeviceId,
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(ciphertext),
        };
    }

    public static ClipPayload Open(ClipEnvelope envelope, ReadOnlySpan<byte> pairKey)
    {
        try
        {
            var nonce = Convert.FromBase64String(envelope.Nonce);
            var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
            if (nonce.Length != 12 || ciphertext.Length < 16)
            {
                throw new EnvelopeCryptoException("The envelope nonce or ciphertext is malformed.");
            }

            var plaintext = ChaCha20Poly1305Cipher.Decrypt(pairKey, nonce, ciphertext);
            return JsonSerializer.Deserialize<ClipPayload>(plaintext, WireJson.Options)
                ?? throw new EnvelopeCryptoException("The envelope payload is empty.");
        }
        catch (Exception exception) when (
            exception is InvalidCipherTextException
                or FormatException
                or JsonException
                or ArgumentException)
        {
            throw new EnvelopeCryptoException("The envelope could not be decrypted.", exception);
        }
    }
}
