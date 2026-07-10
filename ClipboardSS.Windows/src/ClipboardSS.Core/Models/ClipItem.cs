namespace ClipboardSS.Core.Models;

public sealed record ClipItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required ClipType Type { get; set; }
    public required DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastCopiedAt { get; set; }
    public bool IsPinned { get; set; }
    public string? Text { get; set; }
    public string? ImagePath { get; set; }
    public required string PreviewText { get; set; }
    public required string ContentHash { get; set; }

    public string ResolveImagePath(string baseDirectory) =>
        ImagePath is null ? baseDirectory : Path.Combine(baseDirectory, ImagePath);
}
