namespace ClipboardSS.Core.Sync;

/// <summary>Decides whether received bytes are an image that is safe to store and render.</summary>
public interface IImageValidator
{
    bool IsValidImage(ReadOnlySpan<byte> data);
}

/// <summary>
/// Platform-neutral validator that accepts only data starting with a known image
/// signature (PNG, JPEG, GIF, BMP, TIFF, WebP).
/// </summary>
public sealed class MagicNumberImageValidator : IImageValidator
{
    private static ReadOnlySpan<byte> Png => [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    private static ReadOnlySpan<byte> PngHeaderChunk => [0x49, 0x48, 0x44, 0x52]; // "IHDR"
    private static ReadOnlySpan<byte> Jpeg => [0xFF, 0xD8, 0xFF];
    private static ReadOnlySpan<byte> Gif87 => "GIF87a"u8;
    private static ReadOnlySpan<byte> Gif89 => "GIF89a"u8;
    private static ReadOnlySpan<byte> Bmp => "BM"u8;
    private static ReadOnlySpan<byte> TiffLittleEndian => [0x49, 0x49, 0x2A, 0x00];
    private static ReadOnlySpan<byte> TiffBigEndian => [0x4D, 0x4D, 0x00, 0x2A];
    private static ReadOnlySpan<byte> Riff => "RIFF"u8;
    private static ReadOnlySpan<byte> WebP => "WEBP"u8;

    public bool IsValidImage(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith(Png))
        {
            // The first chunk of every PNG is IHDR (length at 8..11, type at 12..15).
            return data.Length >= 16 && data[12..16].SequenceEqual(PngHeaderChunk);
        }

        return data.StartsWith(Jpeg)
            || data.StartsWith(Gif87)
            || data.StartsWith(Gif89)
            || data.StartsWith(Bmp)
            || data.StartsWith(TiffLittleEndian)
            || data.StartsWith(TiffBigEndian)
            || (data.Length >= 12 && data.StartsWith(Riff) && data[8..12].SequenceEqual(WebP));
    }
}
