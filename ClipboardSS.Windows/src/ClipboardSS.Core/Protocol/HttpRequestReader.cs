namespace ClipboardSS.Core.Protocol;

/// <summary>
/// Reads one HTTP request from a stream: the head is parsed once (capped at
/// <see cref="HttpCodec.MaxHeaderSize"/>), then exactly the declared Content-Length is read.
/// Memory grows with the bytes actually received, never with the length a peer merely declares.
/// </summary>
public static class HttpRequestReader
{
    /// <summary>Initial body buffer and per-read chunk size.</summary>
    public const int BodyChunkSize = 64 * 1024;

    /// <exception cref="HttpCodecException">Incomplete head (EOF), HeadersTooLarge,
    /// PayloadTooLarge or InvalidFormat.</exception>
    /// <exception cref="EndOfStreamException">The peer closed before sending the full body.</exception>
    public static async Task<HttpRequest> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        // Room for the largest allowed head plus its terminator; anything bigger is rejected
        // by TryParseHead before this fills up.
        var headBuffer = new byte[HttpCodec.MaxHeaderSize + 4];
        var filled = 0;
        HttpHead head;
        while (!HttpCodec.TryParseHead(headBuffer.AsSpan(0, filled), out head))
        {
            var count = await stream.ReadAsync(headBuffer.AsMemory(filled), cancellationToken);
            if (count == 0)
            {
                throw new HttpCodecException(HttpCodecError.Incomplete);
            }

            filled += count;
        }

        var contentLength = head.ContentLength;
        var alreadyRead = Math.Min(filled - head.HeaderLength, contentLength);
        var body = new byte[Math.Min(contentLength, Math.Max(alreadyRead, BodyChunkSize))];
        headBuffer.AsSpan(head.HeaderLength, alreadyRead).CopyTo(body);

        var received = alreadyRead;
        while (received < contentLength)
        {
            if (received == body.Length)
            {
                // Grow geometrically, never past the declared length.
                var grown = new byte[(int)Math.Min((long)body.Length * 2, contentLength)];
                body.AsSpan(0, received).CopyTo(grown);
                body = grown;
            }

            var want = Math.Min(body.Length - received, BodyChunkSize);
            var count = await stream.ReadAsync(body.AsMemory(received, want), cancellationToken);
            if (count == 0)
            {
                throw new EndOfStreamException();
            }

            received += count;
        }

        return new HttpRequest(head.Method, head.Path, head.Headers, body);
    }
}
