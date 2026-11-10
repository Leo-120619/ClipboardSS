using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace ClipboardSS.Core.Crypto;

public sealed record PairingResult(byte[] PairKey, string ConfirmCode);

public sealed class PairingException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public sealed class PairingSession
{
    private static readonly byte[] PairKeySalt = Encoding.UTF8.GetBytes("ClipboardSS_PairKey");
    private static readonly byte[] ConfirmCodeSalt = Encoding.UTF8.GetBytes("ClipboardSS_ConfirmCode");
    private readonly X25519PrivateKeyParameters _privateKey;

    public PairingSession()
        : this(new X25519PrivateKeyParameters(new SecureRandom()))
    {
    }

    private PairingSession(X25519PrivateKeyParameters privateKey)
    {
        _privateKey = privateKey;
        EphemeralPublicKey = privateKey.GeneratePublicKey().GetEncoded();
    }

    public byte[] EphemeralPublicKey { get; }

    public static PairingSession FromPrivateKey(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != X25519PrivateKeyParameters.KeySize)
        {
            throw new ArgumentException("An X25519 private key must be 32 bytes.", nameof(privateKey));
        }

        return new PairingSession(new X25519PrivateKeyParameters(privateKey.ToArray()));
    }

    /// <summary>Length of the random salt the initiator commits with (pairing v2).</summary>
    public const int SaltLength = 16;

    public static byte[] RandomSalt() => RandomNumberGenerator.GetBytes(SaltLength);

    /// <summary>
    /// <c>SHA256(initiatorPublicKey || salt)</c>: sent in <c>/v1/pair/start</c> so the initiator's key
    /// stays hidden until the target has answered with its own.
    /// </summary>
    public static byte[] Commitment(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> salt)
    {
        var buffer = new byte[publicKey.Length + salt.Length];
        publicKey.CopyTo(buffer);
        salt.CopyTo(buffer.AsSpan(publicKey.Length));
        return SHA256.HashData(buffer);
    }

    /// <summary>Constant-time check that <paramref name="publicKey"/> and <paramref name="salt"/> open the commitment.</summary>
    public static bool CommitmentMatches(ReadOnlySpan<byte> commitment, ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> salt) =>
        CryptographicOperations.FixedTimeEquals(commitment, Commitment(publicKey, salt));

    /// <summary>
    /// Derives <c>pairKey</c> and the 6-digit <c>confirmCode</c> both screens show. HKDF <c>info</c> is
    /// the transcript <c>code || initiatorPublicKey || targetPublicKey</c>.
    /// </summary>
    public PairingResult CompletePairing(
        ReadOnlySpan<byte> remotePublicKey,
        bool isInitiator,
        string code)
    {
        if (remotePublicKey.Length != X25519PublicKeyParameters.KeySize)
        {
            throw new PairingException("The remote X25519 public key must be 32 bytes.");
        }

        try
        {
            var sharedSecret = DeriveSharedSecret(remotePublicKey);
            var codeBytes = Encoding.ASCII.GetBytes(code);
            var initiatorPublicKey = isInitiator ? EphemeralPublicKey : remotePublicKey.ToArray();
            var targetPublicKey = isInitiator ? remotePublicKey.ToArray() : EphemeralPublicKey;
            var info = new byte[codeBytes.Length + initiatorPublicKey.Length + targetPublicKey.Length];
            codeBytes.CopyTo(info, 0);
            initiatorPublicKey.CopyTo(info, codeBytes.Length);
            targetPublicKey.CopyTo(info, codeBytes.Length + initiatorPublicKey.Length);
            var pairKey = HkdfSha256.Derive(sharedSecret, PairKeySalt, info, 32);
            var codeKey = HkdfSha256.Derive(sharedSecret, ConfirmCodeSalt, info, 4);
            var codeValue = BinaryPrimitives.ReadUInt32BigEndian(codeKey) % 1_000_000;
            return new PairingResult(pairKey, codeValue.ToString("D6"));
        }
        catch (Exception exception) when (exception is not PairingException)
        {
            throw new PairingException("Could not complete X25519 key agreement.", exception);
        }
    }

    public byte[] DeriveSharedSecret(ReadOnlySpan<byte> remotePublicKey)
    {
        if (remotePublicKey.Length != X25519PublicKeyParameters.KeySize)
        {
            throw new PairingException("The remote X25519 public key must be 32 bytes.");
        }

        var remoteKey = new X25519PublicKeyParameters(remotePublicKey.ToArray());
        var sharedSecret = new byte[X25519PrivateKeyParameters.SecretSize];
        _privateKey.GenerateSecret(remoteKey, sharedSecret, 0);
        return sharedSecret;
    }

    public static byte[] GenerateConfirmationProof(
        ReadOnlySpan<byte> pairKey,
        Guid initiatorId,
        Guid targetId) =>
        HMACSHA256.HashData(pairKey, Encoding.UTF8.GetBytes(ConfirmationMessage(initiatorId, targetId)));

    public static bool VerifyConfirmationProof(
        ReadOnlySpan<byte> proof,
        ReadOnlySpan<byte> pairKey,
        Guid initiatorId,
        Guid targetId) =>
        CryptographicOperations.FixedTimeEquals(
            proof,
            GenerateConfirmationProof(pairKey, initiatorId, targetId));

    public static string ConfirmationMessage(Guid initiatorId, Guid targetId) =>
        $"confirm{initiatorId:D}{targetId:D}".ToLowerInvariant();
}
