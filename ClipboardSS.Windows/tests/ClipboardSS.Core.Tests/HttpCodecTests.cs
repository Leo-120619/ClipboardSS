using System.Text;
using ClipboardSS.Core.Protocol;

namespace ClipboardSS.Core.Tests;

public sealed class HttpCodecTests
{
    [Fact]
    public void ParsesRequestUsingContentLengthAndLowercaseHeaders()
    {
        var data = Encoding.UTF8.GetBytes(
            "POST /v1/clip HTTP/1.1\r\nContent-Length: 5\r\nX-Test: a: b\r\n\r\nhelloignored");

        var request = HttpCodec.ParseRequest(data);

        Assert.Equal("POST", request.Method);
        Assert.Equal("/v1/clip", request.Path);
        Assert.Equal("5", request.Headers["content-length"]);
        Assert.Equal("a: b", request.Headers["x-test"]);
        Assert.Equal("hello", Encoding.UTF8.GetString(request.Body));
    }

    [Fact]
    public void RejectsIncompleteAndOversizedBodies()
    {
        var incomplete = Assert.Throws<HttpCodecException>(() => HttpCodec.ParseRequest(
            "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nno"u8));
        Assert.Equal(HttpCodecError.Incomplete, incomplete.Error);

        var oversized = Assert.Throws<HttpCodecException>(() => HttpCodec.ParseRequest(
            Encoding.UTF8.GetBytes(
                $"POST / HTTP/1.1\r\nContent-Length: {HttpCodec.MaxBodySize + 1}\r\n\r\n")));
        Assert.Equal(HttpCodecError.PayloadTooLarge, oversized.Error);
    }

    [Fact]
    public void EncodersAlwaysAddContentLengthAndConnectionClose()
    {
        var encoded = HttpCodec.EncodeResponse(new HttpResponse(
            401,
            new Dictionary<string, string> { ["Content-Type"] = "application/json" },
            "{}"u8.ToArray()));
        var text = Encoding.UTF8.GetString(encoded);

        Assert.StartsWith("HTTP/1.1 401 Unauthorized\r\n", text);
        Assert.Contains("Content-Length: 2\r\n", text);
        Assert.Contains("Connection: close\r\n", text);
        Assert.EndsWith("\r\n\r\n{}", text);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("+5")]
    [InlineData("0x10")]
    [InlineData("5 5")]
    [InlineData("")]
    public void NegativeContentLength_IsInvalid(string value)
    {
        var data = Encoding.UTF8.GetBytes($"POST /v1/clip HTTP/1.1\r\nContent-Length: {value}\r\n\r\nhello");

        var parse = Assert.Throws<HttpCodecException>(() => HttpCodec.ParseRequest(data));
        Assert.Equal(HttpCodecError.InvalidFormat, parse.Error);

        var head = Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(data, out _));
        Assert.Equal(HttpCodecError.InvalidFormat, head.Error);
    }

    [Fact]
    public void HeadersOver16KB_AreRejected()
    {
        Assert.Equal(16 * 1024, HttpCodec.MaxHeaderSize);

        // No terminator within the first MaxHeaderSize bytes: give up instead of buffering forever.
        var unterminated = Encoding.UTF8.GetBytes(
            "POST /v1/clip HTTP/1.1\r\nX-Pad: " + new string('a', HttpCodec.MaxHeaderSize));
        var head = Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(unterminated, out _));
        Assert.Equal(HttpCodecError.HeadersTooLarge, head.Error);
        var parse = Assert.Throws<HttpCodecException>(() => HttpCodec.ParseRequest(unterminated));
        Assert.Equal(HttpCodecError.HeadersTooLarge, parse.Error);

        // A complete but oversized header block is rejected too.
        var terminated = Encoding.UTF8.GetBytes(
            "POST /v1/clip HTTP/1.1\r\nX-Pad: " + new string('a', HttpCodec.MaxHeaderSize) + "\r\n\r\n");
        Assert.Equal(
            HttpCodecError.HeadersTooLarge,
            Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(terminated, out _)).Error);

        // A short, still-unterminated head is merely incomplete.
        Assert.False(HttpCodec.TryParseHead("POST /v1/clip HTTP/1.1\r\nX-Pad: a"u8, out _));
    }

    [Fact]
    public void TryParseHead_ReturnsHeaderLengthAndContentLength()
    {
        const string headText = "POST /v1/clip HTTP/1.1\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\n";
        var data = Encoding.UTF8.GetBytes(headText + "he");

        Assert.True(HttpCodec.TryParseHead(data, out var head));
        Assert.Equal("POST", head.Method);
        Assert.Equal("/v1/clip", head.Path);
        Assert.Equal("yes", head.Headers["x-test"]);
        Assert.Equal(Encoding.UTF8.GetByteCount(headText), head.HeaderLength);
        Assert.Equal(5, head.ContentLength);

        Assert.True(HttpCodec.TryParseHead("GET /v1/id HTTP/1.1\r\nHost: x\r\n\r\n"u8, out var noBody));
        Assert.Equal(0, noBody.ContentLength);

        var oversized = Encoding.UTF8.GetBytes(
            $"POST / HTTP/1.1\r\nContent-Length: {HttpCodec.MaxBodySize + 1}\r\n\r\n");
        Assert.Equal(
            HttpCodecError.PayloadTooLarge,
            Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(oversized, out _)).Error);

        var huge = "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n"u8.ToArray();
        Assert.Equal(
            HttpCodecError.PayloadTooLarge,
            Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(huge, out _)).Error);
    }

    private static byte[] HeadOfLength(int length)
    {
        const string prefix = "GET /v1/id HTTP/1.1\r\nX-Pad: ";
        return Encoding.ASCII.GetBytes(prefix + new string('a', length - prefix.Length) + "\r\n\r\n");
    }

    [Fact]
    public void HeadOfExactlyMaxHeaderSize_IsAccepted()
    {
        var data = HeadOfLength(HttpCodec.MaxHeaderSize);

        Assert.True(HttpCodec.TryParseHead(data, out var head));
        Assert.Equal(HttpCodec.MaxHeaderSize + 4, head.HeaderLength);
        Assert.Equal("/v1/id", HttpCodec.ParseRequest(data).Path);
    }

    [Fact]
    public void HeadOneByteOverMaxHeaderSize_IsRejected()
    {
        var data = HeadOfLength(HttpCodec.MaxHeaderSize + 1);

        Assert.Equal(
            HttpCodecError.HeadersTooLarge,
            Assert.Throws<HttpCodecException>(() => HttpCodec.TryParseHead(data, out _)).Error);
        Assert.Equal(
            HttpCodecError.HeadersTooLarge,
            Assert.Throws<HttpCodecException>(() => HttpCodec.ParseRequest(data)).Error);
    }

    /// <summary>Serves a fixed byte sequence a few bytes per read, synchronously, then EOF.</summary>
    private sealed class TricklingStream(byte[] data, int maxPerRead) : Stream
    {
        private int _position;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

        public override int Read(Span<byte> buffer)
        {
            var count = Math.Min(Math.Min(buffer.Length, maxPerRead), data.Length - _position);
            data.AsSpan(_position, count).CopyTo(buffer);
            _position += count;
            return count;
        }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(Read(buffer.Span));
    }

    [Fact]
    public async Task ReadRequest_ReassemblesBodySplitAcrossManyReads()
    {
        var body = new byte[300 * 1024];
        new Random(7).NextBytes(body);
        var data = HttpCodec.EncodeRequest(
            new HttpRequest("POST", "/v1/clip", new Dictionary<string, string>(), body),
            "peer");

        var request = await HttpRequestReader.ReadAsync(new TricklingStream(data, 1000), CancellationToken.None);

        Assert.Equal("POST", request.Method);
        Assert.Equal("/v1/clip", request.Path);
        Assert.Equal(body, request.Body);
    }

    [Fact]
    public async Task ReadRequest_DoesNotPreallocateDeclaredContentLength()
    {
        var data = Encoding.ASCII.GetBytes(
            $"POST /v1/clip HTTP/1.1\r\nContent-Length: {HttpCodec.MaxBodySize}\r\n\r\nonly-a-few-bytes");
        var stream = new TricklingStream(data, 64 * 1024);

        // The fake stream completes synchronously, so the whole read stays on this thread.
        var before = GC.GetAllocatedBytesForCurrentThread();
        await Assert.ThrowsAsync<EndOfStreamException>(
            () => HttpRequestReader.ReadAsync(stream, CancellationToken.None));
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;

        // Memory must track bytes received, not the 20 MB the peer merely declared.
        Assert.True(allocated < 1024 * 1024, $"allocated {allocated} bytes");
    }

    [Fact]
    public async Task ReadRequest_EofBeforeHeadEnds_IsIncomplete()
    {
        var stream = new TricklingStream("POST /v1/clip HTTP/1.1\r\nContent-Le"u8.ToArray(), 8);

        var error = await Assert.ThrowsAsync<HttpCodecException>(
            () => HttpRequestReader.ReadAsync(stream, CancellationToken.None));
        Assert.Equal(HttpCodecError.Incomplete, error.Error);
    }
}
