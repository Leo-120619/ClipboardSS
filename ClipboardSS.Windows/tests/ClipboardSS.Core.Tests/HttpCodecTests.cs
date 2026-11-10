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
}
