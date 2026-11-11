namespace ClipboardSS.Core.Models;

public sealed record ClipEnvelope
{
    /// <summary>Required on the wire: a missing "v" is rejected rather than assumed current.</summary>
    public required int V { get; init; }
    public required Guid SourceDeviceId { get; init; }
    public required string Nonce { get; init; }
    public required string Ciphertext { get; init; }
}
