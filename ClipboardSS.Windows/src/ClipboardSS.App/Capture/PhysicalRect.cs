using System.Windows;

namespace ClipboardSS.App.Capture;

/// <summary>
/// A rectangle in the virtual desktop's physical-pixel coordinate space.
/// WPF uses device-independent pixels, while capture and OCR bounds use pixels.
/// </summary>
public readonly record struct PhysicalRect(int X, int Y, int Width, int Height)
{
    public bool IsUsable => Width > 1 && Height > 1;

    public Rect ToDipRect(Window window)
    {
        var topLeft = window.PointFromScreen(new Point(X, Y));
        var bottomRight = window.PointFromScreen(new Point(X + Width, Y + Height));
        return new Rect(topLeft, bottomRight);
    }

    public static PhysicalRect FromScreenPoints(Point start, Point end)
    {
        var left = (int)Math.Floor(Math.Min(start.X, end.X));
        var top = (int)Math.Floor(Math.Min(start.Y, end.Y));
        var right = (int)Math.Ceiling(Math.Max(start.X, end.X));
        var bottom = (int)Math.Ceiling(Math.Max(start.Y, end.Y));
        return new PhysicalRect(left, top, right - left, bottom - top);
    }
}
