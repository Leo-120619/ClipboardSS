using System.Buffers.Binary;
using System.Text;

namespace ClipboardSS.Core.Crypto;

public static class FileTransferCrypto
{
    private static readonly byte[] Salt = Encoding.ASCII.GetBytes("ClipboardSS_FileKey");
    public static byte[] DeriveFileKey(ReadOnlySpan<byte> pairKey, string transferId) =>
        HkdfSha256.Derive(pairKey, Salt, Encoding.ASCII.GetBytes(transferId.ToLowerInvariant()), 32);
    public static byte[] NonceForChunk(long chunkIndex)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(chunkIndex);
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), checked((ulong)chunkIndex));
        return nonce;
    }
    public static byte[] SealChunk(ReadOnlySpan<byte> key, long index, ReadOnlySpan<byte> plaintext) =>
        ChaCha20Poly1305Cipher.Encrypt(key, NonceForChunk(index), plaintext);
    public static byte[] OpenChunk(ReadOnlySpan<byte> key, long index, ReadOnlySpan<byte> body) =>
        ChaCha20Poly1305Cipher.Decrypt(key, NonceForChunk(index), body);
}
