using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Sync;

public interface IPeerTransport
{
    Task<byte[]> SendAsync(byte[] data, Peer peer, CancellationToken cancellationToken = default);
}
