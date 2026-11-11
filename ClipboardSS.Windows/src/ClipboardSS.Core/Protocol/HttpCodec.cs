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

/// <summary>
/// A parsed request head. <see cref="HeaderLength"/> counts the bytes up to and including the
/// blank line; <see cref="ContentLength"/> is the declared body size (0 when absent).
/// </summary>
public sealed record HttpHead(
    string Method,
    string Path,
    IReadOnlyDictionary<string, string> Headers,
    int HeaderLength,
    int ContentLength);

public enum HttpCodecError
{
    Incomplete,
    InvalidFormat,
    PayloadTooLarge,
    HeadersTooLarge,
}

public sealed class HttpCodecException(HttpCodecError error)
    : Exception($"HTTP codec error: {error}")
{
    public HttpCodecError Error { get; } = error;
}

public static class HttpCodec
{
    public const int MaxBodySize = 20 * 1024 * 1024;
    public const int MaxHeaderSize = 16 * 1024;
    private static readonly byte[] HeaderTerminator = "\r\n\r\n"u8.ToArray();

    public static HttpRequest ParseRequest(ReadOnlySpan<byte> data)
    {
        var (head, body) = Split(data);
        var (method, path, headers) = ParseRequestHead(head);
        return new HttpRequest(method, path, headers, ReadBody(body, headers));
    }

    /// <summary>
    /// Parses only the request head so a server can then read exactly
    /// <see cref="HttpHead.ContentLength"/> more bytes. Returns false while the head is still
    /// incomplete; throws <see cref="HttpCodecError.HeadersTooLarge"/> once more than
    /// <see cref="MaxHeaderSize"/> bytes arrive without a terminator, and
    /// <see cref="HttpCodecError.PayloadTooLarge"/> or <see cref="HttpCodecError.InvalidFormat"/>
    /// for a bad Content-Length.
    /// </summary>
    public static bool TryParseHead(ReadOnlySpan<byte> data, out HttpHead head)
    {
        var separatorIndex = FindHeaderTerminator(data);
        if (separatorIndex < 0)
        {
            head = null!;
            return false;
        }

        var (method, path, headers) = ParseRequestHead(data[..separatorIndex].ToArray());
        var contentLength = headers.TryGetValue("content-length", out var value)
            ? ParseContentLength(value)
            : 0;
        head = new HttpHead(method, path, headers, separatorIndex + HeaderTerminator.Length, contentLength);
        return true;
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

    private static (string Method, string Path, Dictionary<string, string> Headers) ParseRequestHead(byte[] head)
    {
        var lines = ReadHeadLines(head);
        var requestLine = lines[0].Split(' ', StringSplitOptions.None);
        if (requestLine.Length != 3)
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        return (requestLine[0], requestLine[1], ParseHeaders(lines.Skip(1)));
    }

    /// <summary>
    /// Index of the blank line ending the head, or -1 while incomplete. Never looks past
    /// <see cref="MaxHeaderSize"/> bytes so a peer that never terminates cannot make us buffer
    /// without bound.
    /// </summary>
    private static int FindHeaderTerminator(ReadOnlySpan<byte> data)
    {
        var searchLimit = MaxHeaderSize + HeaderTerminator.Length;
        var separatorIndex = data[..Math.Min(data.Length, searchLimit)].IndexOf(HeaderTerminator);
        if (separatorIndex >= 0)
        {
            return separatorIndex;
        }

        if (data.Length >= searchLimit)
        {
            throw new HttpCodecException(HttpCodecError.HeadersTooLarge);
        }

        return -1;
    }

    private static (byte[] Head, byte[] Body) Split(ReadOnlySpan<byte> data)
    {
        var separatorIndex = FindHeaderTerminator(data);
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

        var contentLength = ParseContentLength(value);
        if (body.Length < contentLength)
        {
            throw new HttpCodecException(HttpCodecError.Incomplete);
        }

        return body[..contentLength].ToArray();
    }

    /// <summary>
    /// Only a plain run of ASCII digits (optionally padded with spaces/tabs) is a valid length;
    /// int.TryParse alone would accept "+5" or other signed forms.
    /// </summary>
    private static int ParseContentLength(string value)
    {
        var trimmed = value.Trim(' ', '\t');
        if (trimmed.Length == 0 || !trimmed.All(char.IsAsciiDigit))
        {
            throw new HttpCodecException(HttpCodecError.InvalidFormat);
        }

        // All digits but not representable as int means it is far beyond any allowed size.
        if (!int.TryParse(trimmed, System.Globalization.NumberStyles.None, null, out var contentLength)
            || contentLength > MaxBodySize)
        {
            throw new HttpCodecException(HttpCodecError.PayloadTooLarge);
        }

        return contentLength;
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
        409 => "Conflict",
        410 => "Gone",
        422 => "Unprocessable Content",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        _ => "Status",
    };
}
