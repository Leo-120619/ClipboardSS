namespace ClipboardSS.Core.Models;

public sealed record ClipEnvelope
{
    public int V { get; init; } = 1;
    public required Guid SourceDeviceId { get; init; }
    public required string Nonce { get; init; }
    public required string Ciphertext { get; init; }
}
