namespace ClipboardSS.App;

/// <summary>
/// A small trace of outgoing sync results in the storage directory (<c>sync.log</c>), so "it did not
/// arrive" can be diagnosed. Records counts, device names and error messages only, never clip contents.
/// </summary>
public static class SyncLog
{
    private const long MaxBytes = 256 * 1024;
    private static readonly object Gate = new();

    public static void Write(string storageDirectory, string message)
    {
        try
        {
            lock (Gate)
            {
                var path = Path.Combine(storageDirectory, "sync.log");
                var file = new FileInfo(path);
                // Start over rather than grow without bound.
                if (file.Exists && file.Length > MaxBytes) file.Delete();
                File.AppendAllText(path, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
            // Logging is best effort and must never break a send.
        }
    }
}
