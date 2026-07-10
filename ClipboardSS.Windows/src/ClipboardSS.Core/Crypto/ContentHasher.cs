using System.Security.Cryptography;
using System.Text;

namespace ClipboardSS.Core.Crypto;

public static class ContentHasher
{
    public static string TextHash(string text) => Hash(Encoding.UTF8.GetBytes(text), "text");

    public static string ImageHash(ReadOnlySpan<byte> data) => Hash(data, "image");

    private static string Hash(ReadOnlySpan<byte> data, string @namespace)
    {
        var namespaceBytes = Encoding.UTF8.GetBytes(@namespace);
        var input = new byte[namespaceBytes.Length + 1 + data.Length];
        namespaceBytes.CopyTo(input, 0);
        data.CopyTo(input.AsSpan(namespaceBytes.Length + 1));
        return Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
    }
}
