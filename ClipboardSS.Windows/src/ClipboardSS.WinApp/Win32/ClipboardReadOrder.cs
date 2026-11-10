namespace ClipboardSS.App.Win32;

// Clipboard format preference and CF_UNICODETEXT decoding. Kept free of Windows-only
// dependencies so ClipboardSS.Core.Tests/ClipboardReadOrderTests.cs can link this file.

internal enum ClipboardPayloadKind
{
    Text,
    Png,
    Dib,
}

internal static class ClipboardReadOrder
{
    public const uint CfDib = 8;
    public const uint CfUnicodeText = 13;

    /// <summary>
    /// Formats to try, best first. Text wins over images: apps such as Excel or Word put a
    /// rendered picture next to the text, and the text is what the user copied.
    /// </summary>
    public static IReadOnlyList<ClipboardPayloadKind> Candidates(IReadOnlyCollection<uint> availableFormats, uint pngFormat)
    {
        var candidates = new List<ClipboardPayloadKind>(3);
        if (availableFormats.Contains(CfUnicodeText)) candidates.Add(ClipboardPayloadKind.Text);
        if (pngFormat != 0 && availableFormats.Contains(pngFormat)) candidates.Add(ClipboardPayloadKind.Png);
        if (availableFormats.Contains(CfDib)) candidates.Add(ClipboardPayloadKind.Dib);
        return candidates;
    }

    /// <summary>
    /// CF_UNICODETEXT bytes (the whole GlobalSize block) up to the first NUL. Another process owns
    /// the block, so a missing terminator must end the string at GlobalSize / 2 characters rather
    /// than reading past the allocation.
    /// </summary>
    public static string DecodeUnicodeText(ReadOnlySpan<byte> bytes)
    {
        var characters = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, char>(bytes[..(bytes.Length & ~1)]);
        var terminator = characters.IndexOf('\0');
        return new string(terminator >= 0 ? characters[..terminator] : characters);
    }
}
