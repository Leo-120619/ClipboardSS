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
}
