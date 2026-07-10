namespace ClipboardSS.Core.Sync;

public sealed record ClipboardSnapshot(string? Text, byte[]? ImageData);

public interface IPasteboardClient
{
    long CurrentChangeCount();
    ClipboardSnapshot ReadSnapshot();
    void ClearContents();
    void WriteText(string text);
    void WriteImageData(ReadOnlySpan<byte> data);
}
