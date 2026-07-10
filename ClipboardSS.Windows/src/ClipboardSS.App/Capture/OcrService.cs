using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using ClipboardSS.Core.Selection;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace ClipboardSS.App.Capture;

public sealed record OcrWordBlock(string Id, string Text, RectD Bounds);

public sealed class OcrUnavailableException : InvalidOperationException
{
    public OcrUnavailableException()
        : base("Windows OCR is unavailable. Install an OCR language in Settings > Time & language > Language & region, then run ClipboardSS from its MSIX package.")
    {
    }
}

/// <summary>Offline OCR backed by Windows.Media.Ocr. Bounds are returned in source-image pixels.</summary>
public sealed class OcrService
{
    public async Task<IReadOnlyList<OcrTextBlock>> RecognizeLinesAsync(byte[] pngData)
    {
        var result = await RecognizeAsync(pngData);
        return result.Lines.Select(line => new OcrTextBlock(Guid.NewGuid().ToString("N"), line.Text)).ToArray();
    }

    public async Task<IReadOnlyList<OcrWordBlock>> RecognizeWordsAsync(byte[] pngData)
    {
        var result = await RecognizeAsync(pngData);
        return result.Lines.SelectMany(line => line.Words.Select(word =>
        {
            var bounds = word.BoundingRect;
            return new OcrWordBlock(
                Guid.NewGuid().ToString("N"),
                word.Text,
                new RectD(
                    bounds.X * result.ScaleX,
                    bounds.Y * result.ScaleY,
                    bounds.Width * result.ScaleX,
                    bounds.Height * result.ScaleY));
        })).ToArray();
    }

    private static async Task<OcrResultWithScale> RecognizeAsync(byte[] pngData)
    {
        var prepared = PrepareForOcr(pngData, checked((int)OcrEngine.MaxImageDimension));
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new OcrUnavailableException();
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(prepared.Data);
            await writer.StoreAsync();
            await writer.FlushAsync();
        }

        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var softwareBitmap = await decoder.GetSoftwareBitmapAsync();
        var result = await engine.RecognizeAsync(softwareBitmap);
        return new OcrResultWithScale(result, prepared.ScaleX, prepared.ScaleY);
    }

    private static PreparedImage PrepareForOcr(byte[] pngData, int maxDimension)
    {
        using var sourceStream = new MemoryStream(pngData, writable: false);
        using var source = new Bitmap(sourceStream);
        var longestSide = Math.Max(source.Width, source.Height);
        if (longestSide <= maxDimension)
            return new PreparedImage(pngData, 1, 1);

        var scale = maxDimension / (double)longestSide;
        var width = Math.Max(1, (int)Math.Round(source.Width * scale));
        var height = Math.Max(1, (int)Math.Round(source.Height * scale));
        using var scaled = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(scaled))
        {
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        }

        using var output = new MemoryStream();
        scaled.Save(output, ImageFormat.Png);
        return new PreparedImage(output.ToArray(), source.Width / (double)width, source.Height / (double)height);
    }

    private sealed record PreparedImage(byte[] Data, double ScaleX, double ScaleY);
    private sealed record OcrResultWithScale(Windows.Media.Ocr.OcrResult Result, double ScaleX, double ScaleY)
    {
        public IReadOnlyList<Windows.Media.Ocr.OcrLine> Lines => Result.Lines;
    }
}
