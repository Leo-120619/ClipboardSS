using System.Text;
using ClipboardSS.App.Win32;

namespace ClipboardSS.Core.Tests;

public sealed class ClipboardReadOrderTests
{
    private const uint Png = 0xC123;

    [Fact]
    public void TextIsPreferredWhenTextAndImageFormatsArePresent()
    {
        uint[] available = [ClipboardReadOrder.CfDib, Png, ClipboardReadOrder.CfUnicodeText];

        Assert.Equal(
            [ClipboardPayloadKind.Text, ClipboardPayloadKind.Png, ClipboardPayloadKind.Dib],
            ClipboardReadOrder.Candidates(available, Png));
    }

    [Fact]
    public void ImageOnlyClipboardPrefersPngOverDib()
    {
        Assert.Equal(
            [ClipboardPayloadKind.Png, ClipboardPayloadKind.Dib],
            ClipboardReadOrder.Candidates([ClipboardReadOrder.CfDib, Png], Png));
        Assert.Equal(
            [ClipboardPayloadKind.Dib],
            ClipboardReadOrder.Candidates([ClipboardReadOrder.CfDib], 0));
        Assert.Empty(ClipboardReadOrder.Candidates([], Png));
    }

    [Fact]
    public void UnicodeTextStopsAtTheTerminatorOrTheBufferEnd()
    {
        var terminated = Encoding.Unicode.GetBytes("hello\0garbage");
        Assert.Equal("hello", ClipboardReadOrder.DecodeUnicodeText(terminated));

        // No terminator inside GlobalSize: read at most GlobalSize / 2 characters, never past it.
        var unterminated = Encoding.Unicode.GetBytes("abc").Append((byte)'x').ToArray();
        Assert.Equal("abc", ClipboardReadOrder.DecodeUnicodeText(unterminated));
        Assert.Equal(string.Empty, ClipboardReadOrder.DecodeUnicodeText([]));
    }
}
