using System.Windows.Media.Imaging;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.UI;

/// <summary>
/// Accepts a received image only when it has a known signature and WIC can decode its first frame,
/// so nothing that would later fail to render is ever stored.
/// </summary>
internal sealed class WicImageValidator : IImageValidator
{
    private readonly MagicNumberImageValidator _signature = new();

    public bool IsValidImage(ReadOnlySpan<byte> data)
    {
        if (!_signature.IsValidImage(data)) return false;
        try
        {
            using var stream = new MemoryStream(data.ToArray(), writable: false);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            if (decoder.Frames.Count == 0) return false;
            var frame = decoder.Frames[0];
            return frame.PixelWidth > 0 && frame.PixelHeight > 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
