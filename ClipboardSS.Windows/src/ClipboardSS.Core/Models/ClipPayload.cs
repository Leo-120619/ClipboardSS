namespace ClipboardSS.Core.Models;

public sealed record ClipPayload
{
    public required Guid Id { get; init; }
    public required ClipType Type { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public string? Text { get; init; }
    public string? ImageBase64 { get; init; }
    public string? ImageExtension { get; init; }
    public required string PreviewText { get; init; }
    public required string ContentHash { get; init; }
    public required string SourceDeviceName { get; init; }
}
