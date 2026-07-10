namespace ClipboardSS.Core.Selection;

public readonly record struct PointD(double X, double Y);

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double MinX => Math.Min(X, X + Width);
    public double MinY => Math.Min(Y, Y + Height);
    public double MaxX => Math.Max(X, X + Width);
    public double MaxY => Math.Max(Y, Y + Height);
    public double NormalizedWidth => Math.Abs(Width);
    public double NormalizedHeight => Math.Abs(Height);
    public double Area => NormalizedWidth * NormalizedHeight;
    public PointD Center => new((MinX + MaxX) / 2, (MinY + MaxY) / 2);
    public RectD Standardized => new(MinX, MinY, NormalizedWidth, NormalizedHeight);

    public bool Contains(PointD point) =>
        point.X >= MinX && point.X <= MaxX && point.Y >= MinY && point.Y <= MaxY;

    public RectD? Intersection(RectD other)
    {
        var minX = Math.Max(MinX, other.MinX);
        var minY = Math.Max(MinY, other.MinY);
        var maxX = Math.Min(MaxX, other.MaxX);
        var maxY = Math.Min(MaxY, other.MaxY);
        return maxX <= minX || maxY <= minY
            ? null
            : new RectD(minX, minY, maxX - minX, maxY - minY);
    }
}
