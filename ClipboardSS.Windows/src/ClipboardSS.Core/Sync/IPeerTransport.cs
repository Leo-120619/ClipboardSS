using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Sync;

public interface IPeerTransport
{
    /// <summary>Sends one HTTP request and returns the raw response.</summary>
    /// <param name="timeout">
    /// Limit for this request; null uses the transport's default (10 s for <c>TcpPeerTransport</c>).
    /// Requests the peer answers only after slow work (a held pairing confirm, a file finish that
    /// hashes the file) pass a longer one.
    /// </param>
    Task<byte[]> SendAsync(byte[] data, Peer peer, TimeSpan? timeout = null, CancellationToken cancellationToken = default);
}
