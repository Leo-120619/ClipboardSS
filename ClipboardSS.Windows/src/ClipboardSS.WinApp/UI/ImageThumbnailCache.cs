using System.Collections.Concurrent;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ClipboardSS.App.UI;

internal static class ImageThumbnailCache
{
    private static readonly ConcurrentDictionary<string, WeakReference<ImageSource>> Cache = [];

    public static ImageSource? Load(string path)
    {
        if (!File.Exists(path)) return null;
        var key = $"{path}|{File.GetLastWriteTimeUtc(path).Ticks}";
        if (Cache.TryGetValue(key, out var reference) && reference.TryGetTarget(out var cached))
            return cached;
        try
        {
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.CreateOptions = BitmapCreateOptions.PreservePixelFormat;
            bitmap.DecodePixelWidth = 640;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            Cache[key] = new WeakReference<ImageSource>(bitmap);
            return bitmap;
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException)
        {
            return null;
        }
    }
}
