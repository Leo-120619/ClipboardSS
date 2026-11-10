using System.Buffers.Binary;
using System.Windows.Media.Imaging;

namespace ClipboardSS.App.Win32;

public static class DibCodec
{
    private const int BitmapFileHeaderLength = 14;
    private static ReadOnlySpan<byte> PngMagic => [0x89, 0x50, 0x4e, 0x47];

    public static bool IsPng(ReadOnlySpan<byte> bytes) => bytes.StartsWith(PngMagic);

    public static byte[]? ToPng(ReadOnlySpan<byte> imageBytes)
    {
        if (IsPng(imageBytes)) return imageBytes.ToArray();
        try
        {
            var frame = Decode(imageBytes);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(frame);
            using var output = new MemoryStream();
            encoder.Save(output);
            return output.ToArray();
        }
        catch (Exception exception) when (exception is NotSupportedException or FileFormatException)
        {
            return null;
        }
    }

    public static byte[]? ImageToDib(ReadOnlySpan<byte> imageBytes)
    {
        try
        {
            var frame = Decode(imageBytes);
            var encoder = new BmpBitmapEncoder();
            encoder.Frames.Add(frame);
            using var output = new MemoryStream();
            encoder.Save(output);
            var bmp = output.ToArray();
            return bmp.Length > BitmapFileHeaderLength ? bmp[BitmapFileHeaderLength..] : null;
        }
        catch (Exception exception) when (exception is NotSupportedException or FileFormatException)
        {
            return null;
        }
    }

    public static byte[]? DibToPng(ReadOnlySpan<byte> dibBytes)
    {
        if (dibBytes.Length < 40) return null;
        var headerSize = BinaryPrimitives.ReadUInt32LittleEndian(dibBytes);
        if (headerSize < 40 || headerSize > dibBytes.Length) return null;
        var bitCount = BinaryPrimitives.ReadUInt16LittleEndian(dibBytes[14..]);
        var compression = BinaryPrimitives.ReadUInt32LittleEndian(dibBytes[16..]);
        var colorsUsed = BinaryPrimitives.ReadUInt32LittleEndian(dibBytes[32..]);
        if (colorsUsed == 0 && bitCount <= 8) colorsUsed = 1u << bitCount;
        var pixelOffset = BitmapFileHeaderLength + checked((int)headerSize) + checked((int)colorsUsed * 4);
        if (compression == 3 && headerSize == 40) pixelOffset += 12;

        var bmp = new byte[BitmapFileHeaderLength + dibBytes.Length];
        bmp[0] = 0x42;
        bmp[1] = 0x4d;
        BinaryPrimitives.WriteUInt32LittleEndian(bmp.AsSpan(2), (uint)bmp.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(bmp.AsSpan(10), (uint)pixelOffset);
        dibBytes.CopyTo(bmp.AsSpan(BitmapFileHeaderLength));
        return ToPng(bmp);
    }

    private static BitmapFrame Decode(ReadOnlySpan<byte> imageBytes)
    {
        using var input = new MemoryStream(imageBytes.ToArray(), false);
        var decoder = BitmapDecoder.Create(
            input,
            BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        frame.Freeze();
        return frame;
    }
}
