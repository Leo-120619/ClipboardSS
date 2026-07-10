using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Sync;

public sealed class ClipboardMonitor(IPasteboardClient pasteboard, ClipStore store)
{
    private long? _lastChangeCount;

    public void Poll()
    {
        var currentChangeCount = pasteboard.CurrentChangeCount();
        if (currentChangeCount == _lastChangeCount)
        {
            return;
        }

        _lastChangeCount = currentChangeCount;
        var snapshot = pasteboard.ReadSnapshot();
        if (snapshot.ImageData is { Length: > 0 })
        {
            store.AddImageData(snapshot.ImageData, "png");
            return;
        }

        if (!string.IsNullOrEmpty(snapshot.Text))
        {
            store.AddText(snapshot.Text);
        }
    }
}
