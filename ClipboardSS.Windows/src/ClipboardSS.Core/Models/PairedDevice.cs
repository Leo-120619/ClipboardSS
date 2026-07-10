namespace ClipboardSS.Core.Models;

public sealed record PairedDevice(Guid Id, string Name, string? Host = null);
