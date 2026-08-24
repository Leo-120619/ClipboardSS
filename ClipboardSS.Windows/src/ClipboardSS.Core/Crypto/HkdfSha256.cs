using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;

namespace ClipboardSS.Core.Crypto;

public static class HkdfSha256
{
    public static byte[] Derive(
        ReadOnlySpan<byte> secret,
        ReadOnlySpan<byte> salt,
        ReadOnlySpan<byte> info,
        int outputLength)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(outputLength);
        var generator = new HkdfBytesGenerator(new Sha256Digest());
        generator.Init(new HkdfParameters(secret.ToArray(), salt.ToArray(), info.ToArray()));
        var output = new byte[outputLength];
        generator.GenerateBytes(output, 0, output.Length);
        return output;
    }
}
