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

    public PairingResult CompletePairing(
        ReadOnlySpan<byte> remotePublicKey,
        Guid initiatorId,
        Guid targetId,
        bool isInitiator,
        string code)
    {
        _ = initiatorId;
        _ = targetId;
        _ = isInitiator;

        if (remotePublicKey.Length != X25519PublicKeyParameters.KeySize)
        {
            throw new PairingException("The remote X25519 public key must be 32 bytes.");
        }

        try
        {
            var sharedSecret = DeriveSharedSecret(remotePublicKey);
            var info = Encoding.ASCII.GetBytes(code);
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
