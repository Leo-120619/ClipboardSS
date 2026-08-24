using ClipboardSS.Core.Models;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Sync;

public sealed class ClipboardWriterException(Guid clipId)
    : Exception($"Image data is missing for clip {clipId:D}.")
{
    public Guid ClipId { get; } = clipId;
}

public sealed class ClipboardWriter(IPasteboardClient pasteboard, ClipStore store)
{
    public void Copy(ClipItem clip)
    {
        pasteboard.ClearContents();
        switch (clip.Type)
        {
            case ClipType.Text:
                pasteboard.WriteText(clip.Text ?? string.Empty);
                break;
            case ClipType.Image:
                var path = clip.ResolveImagePath(store.StorageDirectory);
                if (!File.Exists(path))
                {
                    throw new ClipboardWriterException(clip.Id);
                }

                pasteboard.WriteImageData(File.ReadAllBytes(path));
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(clip));
        }

        store.MarkCopied(clip.Id);
    }
}
