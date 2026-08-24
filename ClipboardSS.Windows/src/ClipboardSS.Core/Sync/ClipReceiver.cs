using ClipboardSS.Core.Models;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Sync;

public enum ReceiveStatus
{
    Added,
    Duplicate,
}

public sealed record ReceiveResult(ReceiveStatus Status, ClipItem? Clip = null);

public sealed class ClipReceiver(ClipStore store, IPasteboardClient pasteboard)
{
    public ReceiveResult Receive(ClipPayload payload)
    {
        var initialCount = store.Items.Count;
        ClipItem clip;
        switch (payload.Type)
        {
            case ClipType.Text:
                if (payload.Text is null)
                {
                    throw new InvalidDataException("Missing text payload.");
                }

                clip = store.AddText(payload.Text);
                pasteboard.ClearContents();
                pasteboard.WriteText(payload.Text);
                break;
            case ClipType.Image:
                if (payload.ImageBase64 is null)
                {
                    throw new InvalidDataException("Missing image payload.");
                }

                byte[] imageData;
                try
                {
                    imageData = Convert.FromBase64String(payload.ImageBase64);
                }
                catch (FormatException exception)
                {
                    throw new InvalidDataException("Invalid image payload.", exception);
                }

                clip = store.AddImageData(
                    imageData,
                    payload.ImageExtension ?? "png",
                    payload.PreviewText);
                pasteboard.ClearContents();
                pasteboard.WriteImageData(imageData);
                break;
            default:
                throw new InvalidDataException("Unknown clip type.");
        }

        return initialCount == store.Items.Count
            ? new ReceiveResult(ReceiveStatus.Duplicate)
            : new ReceiveResult(ReceiveStatus.Added, clip);
    }
}
