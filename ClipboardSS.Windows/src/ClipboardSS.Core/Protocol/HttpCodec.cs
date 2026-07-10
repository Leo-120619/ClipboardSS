using System.Text;

namespace ClipboardSS.Core.Protocol;

public sealed record HttpRequest(
    string Method,
    string Path,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body);

public sealed record HttpResponse(
    int StatusCode,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body);

public enum HttpCodecError
{
    Incomplete,
    InvalidFormat,
    PayloadTooLarge,
}

public sealed class HttpCodecException(HttpCodecError error)
    : Exception($"HTTP codec error: {error}")
{
    public HttpCodecError Error { get; } = error;
}

public static class HttpCodec
{
    public const int MaxBodySize = 20 * 1024 * 1024;
    private static readonly byte[] HeaderTerminator = "\r\n\r\n"u8.ToArray();

    public static HttpRequest ParseRequest(ReadOnlySpan<byte> data)
    {
        var (head, body) = Split(data);
        var lines = ReadHeadLines(head);
        var requestLine = lines[0].Split(' ', StringSplitOptions.None);
        if (requestLine.Length != 3)
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        var headers = ParseHeaders(lines.Skip(1));
        return new HttpRequest(requestLine[0], requestLine[1], headers, ReadBody(body, headers));
    }

    public static HttpResponse ParseResponse(ReadOnlySpan<byte> data)
    {
        var (head, body) = Split(data);
        var lines = ReadHeadLines(head);
        var statusLine = lines[0].Split(' ', StringSplitOptions.None);
        if (statusLine.Length < 2 || !int.TryParse(statusLine[1], out var statusCode))
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        var headers = ParseHeaders(lines.Skip(1));
        return new HttpResponse(statusCode, headers, ReadBody(body, headers));
    }

    public static byte[] EncodeRequest(HttpRequest request, string host)
    {
        var headers = new Dictionary<string, string>(request.Headers, StringComparer.OrdinalIgnoreCase)
        {
            ["Content-Length"] = request.Body.Length.ToString(),
            ["Host"] = host,
            ["Connection"] = "close",
        };
        return EncodeHeadAndBody($"{request.Method} {request.Path} HTTP/1.1", headers, request.Body);
    }

    public static byte[] EncodeResponse(HttpResponse response)
    {
        var headers = new Dictionary<string, string>(response.Headers, StringComparer.OrdinalIgnoreCase)
        {
            ["Content-Length"] = response.Body.Length.ToString(),
            ["Connection"] = "close",
        };
        return EncodeHeadAndBody(
            $"HTTP/1.1 {response.StatusCode} {ReasonPhrase(response.StatusCode)}",
            headers,
            response.Body);
    }

    private static (byte[] Head, byte[] Body) Split(ReadOnlySpan<byte> data)
    {
        var separatorIndex = data.IndexOf(HeaderTerminator);
        if (separatorIndex < 0)
        {
            throw new HttpCodecException(HttpCodecError.Incomplete);
        }

        return (
            data[..separatorIndex].ToArray(),
            data[(separatorIndex + HeaderTerminator.Length)..].ToArray());
    }

    private static string[] ReadHeadLines(byte[] head)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(head);
        }
        catch (DecoderFallbackException)
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        var lines = text.Split("\r\n", StringSplitOptions.None);
        if (lines.Length == 0 || lines[0].Length == 0)
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        return lines;
    }

    private static Dictionary<string, string> ParseHeaders(IEnumerable<string> lines)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines)
        {
            var separator = line.IndexOf(": ", StringComparison.Ordinal);
            if (separator > 0)
            {
                headers[line[..separator].ToLowerInvariant()] = line[(separator + 2)..];
            }
        }

        return headers;
    }

    private static byte[] ReadBody(ReadOnlySpan<byte> body, IReadOnlyDictionary<string, string> headers)
    {
        if (!headers.TryGetValue("content-length", out var value))
        {
            if (body.Length > MaxBodySize)
            {
                throw new HttpCodecException(HttpCodecError.PayloadTooLarge);
            }

            return body.ToArray();
        }

        if (!int.TryParse(value, out var contentLength) || contentLength < 0)
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        if (contentLength > MaxBodySize)
        {
            throw new HttpCodecException(HttpCodecError.PayloadTooLarge);
        }

        if (body.Length < contentLength)
        {
            throw new HttpCodecException(HttpCodecError.Incomplete);
        }

        return body[..contentLength].ToArray();
    }

    private static byte[] EncodeHeadAndBody(
        string startLine,
        IReadOnlyDictionary<string, string> headers,
        byte[] body)
    {
        var builder = new StringBuilder(startLine).Append("\r\n");
        foreach (var (key, value) in headers)
        {
            builder.Append(key).Append(": ").Append(value).Append("\r\n");
        }

        var head = Encoding.UTF8.GetBytes(builder.Append("\r\n").ToString());
        var result = new byte[head.Length + body.Length];
        head.CopyTo(result, 0);
        body.CopyTo(result, head.Length);
        return result;
    }

    private static string ReasonPhrase(int statusCode) => statusCode switch
    {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        _ => "Status",
    };
}
