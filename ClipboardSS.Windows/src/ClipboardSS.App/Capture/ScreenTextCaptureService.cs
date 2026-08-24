using ClipboardSS.Core.Selection;
using Forms = System.Windows.Forms;

namespace ClipboardSS.App.Capture;

public sealed record ScreenSnapshot(uint DisplayId, PhysicalRect Bounds, byte[] PngData);

public sealed record ScreenTextCapture(
    IReadOnlyList<ScreenTextBlock> Blocks,
    IReadOnlyDictionary<uint, ScreenSnapshot> Snapshots);

public sealed class ScreenTextCaptureService
{
    private readonly ScreenshotCaptureService _screenCapture;
    private readonly OcrService _ocr;

    public ScreenTextCaptureService(ScreenshotCaptureService screenCapture, OcrService ocr)
    {
        _screenCapture = screenCapture;
        _ocr = ocr;
    }

    public async Task<ScreenTextCapture> CaptureAllDisplaysAsync(CancellationToken cancellationToken = default)
    {
        var blocks = new List<ScreenTextBlock>();
        var snapshots = new Dictionary<uint, ScreenSnapshot>();
        var displays = Forms.Screen.AllScreens;
        for (var index = 0; index < displays.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var bounds = displays[index].Bounds;
            var region = new PhysicalRect(bounds.X, bounds.Y, bounds.Width, bounds.Height);
            var png = _screenCapture.CapturePng(region);
            var displayId = (uint)index;
            snapshots.Add(displayId, new ScreenSnapshot(displayId, region, png));

            var words = await _ocr.RecognizeWordsAsync(png);
            blocks.AddRange(words.Select(word => new ScreenTextBlock
            {
                Id = word.Id,
                Text = word.Text,
                Bounds = new RectD(
                    region.X + word.Bounds.X,
                    region.Y + word.Bounds.Y,
                    word.Bounds.Width,
                    word.Bounds.Height),
                DisplayId = displayId,
                Source = ScreenTextSource.Ocr,
            }));
        }

        var deduplicated = ScreenTextSelectionState.Deduplicated(blocks);
        if (deduplicated.Count == 0)
            throw new InvalidOperationException("No selectable screen text was detected.");
        return new ScreenTextCapture(deduplicated, snapshots);
    }
}
