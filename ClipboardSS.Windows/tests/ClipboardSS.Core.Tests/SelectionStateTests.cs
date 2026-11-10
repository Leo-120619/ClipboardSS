using ClipboardSS.Core.Selection;

namespace ClipboardSS.Core.Tests;

public sealed class SelectionStateTests
{
    [Fact]
    public void OcrSelectionJoinsSelectedBlocksInSourceOrder()
    {
        var selection = new OcrSelectionState([
            new OcrTextBlock("a", "Alpha"),
            new OcrTextBlock("b", "Beta"),
        ]);

        Assert.False(selection.CanCopySelection);
        selection.Toggle("b");
        selection.Toggle("a");

        Assert.True(selection.CanCopySelection);
        Assert.Equal("Alpha\nBeta", selection.SelectedText);
    }

    [Fact]
    public void RectangleSelectionUsesStandardizedBoundsAndBlockCenters()
    {
        var selection = State(
            Block("a", "Alpha", 10, 10, 80, 20),
            Block("b", "Beta", 120, 10, 80, 20, ScreenTextSource.Accessibility),
            Block("c", "Gamma", 260, 10, 80, 20));

        selection.SelectBlocks(new RectD(220, 60, -220, -60));

        Assert.Equal(["a", "b"], selection.SelectedIds.Order());
        Assert.Equal("Alpha Beta", selection.SelectedText);
    }

    [Fact]
    public void SelectedTextUsesReadingOrderNotClickOrder()
    {
        var selection = State(
            Block("top", "First", 20, 20, 80, 18),
            Block("bottom", "Second", 20, 60, 80, 18));

        selection.Toggle("bottom");
        selection.Toggle("top");

        Assert.Equal("First\nSecond", selection.SelectedText);
    }

    [Fact]
    public void DedupePrefersAccessibilityByGeometryEvenWhenTextDiffers()
    {
        var blocks = ScreenTextSelectionState.Deduplicated([
            Block("ocr", "lmport", 20, 20, 100, 20),
            Block("ax", "import", 22, 21, 96, 18, ScreenTextSource.Accessibility),
            Block("distinct", "import", 20, 120, 100, 20),
        ]);

        Assert.Equal(["ax", "distinct"], blocks.Select(block => block.Id));
    }

    [Fact]
    public void ExtendSelectLineAndSelectAllMatchReadingOrderRules()
    {
        var selection = new ScreenTextSelectionState([
            Block("w1", "one", 0, 0, 30, 18),
            Block("w2", "two", 40, 1, 30, 18),
            Block("w3", "three", 0, 60, 50, 18),
            Block("other", "other", 0, 0, 10, 10, displayId: 2),
        ]);

        selection.Select("w1");
        selection.Extend("w3");
        Assert.Equal(["w1", "w2", "w3"], selection.SelectedIds.Order());
        Assert.Equal("w1", selection.AnchorId);

        selection.SelectLine("w2");
        Assert.Equal(["w1", "w2"], selection.SelectedIds.Order());

        selection.SelectAll(1);
        Assert.Equal(["w1", "w2", "w3"], selection.SelectedIds.Order());
    }

    [Fact]
    public void RangeSelectionUsesNearestEndpointsAndCanExtendFromAnchor()
    {
        var selection = State(
            Block("w1", "one", 0, 0, 30, 18),
            Block("w2", "two", 40, 0, 30, 18),
            Block("w3", "three", 0, 30, 50, 18));

        selection.SelectRange(new PointD(2, 2), new PointD(45, 2));
        Assert.Equal(["w1", "w2"], selection.SelectedIds.Order());
        selection.ExtendRange(new PointD(2, 35));
        Assert.Equal(["w1", "w2", "w3"], selection.SelectedIds.Order());
    }

    [Fact]
    public void JoinModesAndClearSelectionMatchOverlayBehavior()
    {
        var selection = State(
            Block("w1", "one", 0, 0, 30, 18),
            Block("w2", "two", 0, 30, 30, 18),
            Block("w3", "three", 0, 60, 50, 18));
        selection.SelectAll(1);

        Assert.Equal("one two three", selection.JoinedText(ScreenTextJoinMode.Spaces));
        Assert.Equal("one\ntwo\nthree", selection.JoinedText(ScreenTextJoinMode.Lines));

        selection.ClearSelection();
        Assert.Empty(selection.SelectedIds);
        Assert.Null(selection.AnchorId);
    }

    [Fact]
    public void SortIsStableForNearlyAlignedWords()
    {
        // Each neighbour pair is within the old ±4 px tolerance but the ends are not, so a
        // tolerant comparer is intransitive and the result depended on the input order.
        ScreenTextBlock[] words =
        [
            Block("right", "Right", 100, 0, 40, 18),
            Block("middle", "Middle", 50, 3, 40, 18),
            Block("left", "Left", 0, 6, 40, 18),
            Block("next", "Next", 0, 40, 40, 18),
        ];

        foreach (var permutation in Permutations(words))
        {
            var state = new ScreenTextSelectionState(permutation);
            Assert.Equal(["left", "middle", "right", "next"], state.Blocks.Select(block => block.Id));
            Assert.Equal(
                "Left Middle Right\nNext",
                ScreenTextSelectionState.JoinedText(permutation, ScreenTextJoinMode.Lines));
        }
    }

    private static IEnumerable<ScreenTextBlock[]> Permutations(ScreenTextBlock[] items)
    {
        if (items.Length <= 1)
        {
            yield return items;
            yield break;
        }

        for (var index = 0; index < items.Length; index++)
        {
            var rest = items.Where((_, other) => other != index).ToArray();
            foreach (var tail in Permutations(rest))
            {
                yield return [items[index], .. tail];
            }
        }
    }

    private static ScreenTextSelectionState State(params ScreenTextBlock[] blocks) => new(blocks);

    private static ScreenTextBlock Block(
        string id,
        string text,
        double x,
        double y,
        double width,
        double height,
        ScreenTextSource source = ScreenTextSource.Ocr,
        uint displayId = 1) => new()
        {
            Id = id,
            Text = text,
            Bounds = new RectD(x, y, width, height),
            DisplayId = displayId,
            Source = source,
        };
}
