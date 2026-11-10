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
        catch (Exception)
        {
            // A corrupt or undecodable image file must never take down the UI thread
            // (WIC throws FileFormatException, ArgumentException, COMException, ...).
            return Placeholder;
        }
    }

    private static readonly ImageSource Placeholder = CreatePlaceholder();

    private static ImageSource CreatePlaceholder()
    {
        var drawing = new GeometryDrawing(
            new SolidColorBrush(Color.FromRgb(0x80, 0x80, 0x80)) { Opacity = 0.25 },
            null,
            new RectangleGeometry(new System.Windows.Rect(0, 0, 160, 90)));
        var image = new DrawingImage(drawing);
        image.Freeze();
        return image;
    }
}
