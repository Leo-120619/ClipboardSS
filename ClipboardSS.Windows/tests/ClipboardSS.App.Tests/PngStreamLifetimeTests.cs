using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace ClipboardSS.App.Tests;

public sealed class PngStreamLifetimeTests
{
    // A valid, synthetic 1×1 transparent PNG. This reproduces the stream handoff used by OcrService.
    private static readonly byte[] Png = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL2dgAAAABJRU5ErkJggg==");

    [Fact]
    public async Task DetachingWriterStream_LeavesPngStreamReadableForDecoder()
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(Png);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }

        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);

        Assert.Equal((uint)1, decoder.PixelWidth);
        Assert.Equal((uint)1, decoder.PixelHeight);
    }
}
