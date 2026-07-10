using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;

namespace ClipboardSS.Core.Crypto;

public static class ChaCha20Poly1305Cipher
{
    public static byte[] Encrypt(
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> plaintext,
        ReadOnlySpan<byte> associatedData = default) =>
        Process(true, key, nonce, plaintext, associatedData);

    public static byte[] Decrypt(
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> ciphertextAndTag,
        ReadOnlySpan<byte> associatedData = default) =>
        Process(false, key, nonce, ciphertextAndTag, associatedData);

    private static byte[] Process(
        bool encrypt,
        ReadOnlySpan<byte> key,
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> input,
        ReadOnlySpan<byte> associatedData)
    {
        if (key.Length != 32)
        {
            throw new ArgumentException("ChaCha20-Poly1305 requires a 32-byte key.", nameof(key));
        }

        if (nonce.Length != 12)
        {
            throw new ArgumentException("ChaCha20-Poly1305 requires a 12-byte nonce.", nameof(nonce));
        }

        var cipher = new ChaCha20Poly1305();
        cipher.Init(
            encrypt,
            new AeadParameters(
                new KeyParameter(key.ToArray()),
                128,
                nonce.ToArray(),
                associatedData.IsEmpty ? null : associatedData.ToArray()));

        var inputArray = input.ToArray();
        var output = new byte[cipher.GetOutputSize(inputArray.Length)];
        var count = cipher.ProcessBytes(inputArray, 0, inputArray.Length, output, 0);
        count += cipher.DoFinal(output, count);
        return count == output.Length ? output : output[..count];
    }
}
