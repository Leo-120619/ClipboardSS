namespace ClipboardSS.Core.Models;

/// <param name="ProtocolVersion">
/// Wire protocol version the peer advertised (mDNS TXT <c>v</c> or <c>/v1/id</c> <c>v</c>).
/// Peers resolved without an advertisement (stored host) are assumed current.
/// </param>
public sealed record Peer(Guid Id, string Name, string Host, ushort Port, int ProtocolVersion = WireProtocol.Version)
{
    /// <summary>The peer speaks an older wire protocol: list it, but never send to it.</summary>
    public bool NeedsUpdate => ProtocolVersion < WireProtocol.Version;
}
