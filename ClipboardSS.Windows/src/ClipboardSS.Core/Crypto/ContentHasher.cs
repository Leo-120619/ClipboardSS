using System.Security.Cryptography;
using System.Text;

namespace ClipboardSS.Core.Crypto;

public static class ContentHasher
{
    public static string TextHash(string text) => Hash(Encoding.UTF8.GetBytes(text), "text");

    public static string ImageHash(ReadOnlySpan<byte> data) => Hash(data, "image");

    public static async Task<string> FileHashAsync(Stream stream, CancellationToken cancellationToken = default)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData("file\0"u8);
        var buffer = new byte[128 * 1024];
        int count;
        while ((count = await stream.ReadAsync(buffer, cancellationToken)) > 0)
            hash.AppendData(buffer, 0, count);
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static string Hash(ReadOnlySpan<byte> data, string @namespace)
    {
        var namespaceBytes = Encoding.UTF8.GetBytes(@namespace);
        var input = new byte[namespaceBytes.Length + 1 + data.Length];
        namespaceBytes.CopyTo(input, 0);
        data.CopyTo(input.AsSpan(namespaceBytes.Length + 1));
        return Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
    }
}
