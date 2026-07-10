namespace ClipboardSS.Core.Models;

public sealed record Peer(Guid Id, string Name, string Host, ushort Port);
