namespace ClipboardSS.Core.Selection;

public enum ScreenTextSource
{
    Accessibility,
    Ocr,
}

public enum ScreenTextJoinMode
{
    Lines,
    Spaces,
}

public sealed record ScreenTextBlock
{
    public required string Id { get; init; }
    public required string Text { get; set; }
    public required RectD Bounds { get; set; }
    public required uint DisplayId { get; set; }
    public required ScreenTextSource Source { get; set; }
    public string? LineId { get; set; }
    public PointD Center => Bounds.Center;
}

public sealed class ScreenTextSelectionState
{
    public ScreenTextSelectionState(
        IEnumerable<ScreenTextBlock> blocks,
        IEnumerable<string>? selectedIds = null,
        string? anchorId = null,
        ScreenTextJoinMode joinMode = ScreenTextJoinMode.Lines)
    {
        Blocks = AssignLineIdsIfNeeded(SortedForReading(Deduplicated(blocks))).ToArray();
        SelectedIds = selectedIds?.ToHashSet(StringComparer.Ordinal)
            ?? new HashSet<string>(StringComparer.Ordinal);
        AnchorId = anchorId;
        JoinMode = joinMode;
    }

    public IReadOnlyList<ScreenTextBlock> Blocks { get; }
    public HashSet<string> SelectedIds { get; private set; }
    public string? AnchorId { get; private set; }
    public ScreenTextJoinMode JoinMode { get; set; }
    public bool CanCopySelection => SelectedIds.Count > 0;
    public string SelectedText => JoinedText(JoinMode);

    public string JoinedText(ScreenTextJoinMode mode) =>
        Join(Blocks.Where(block => SelectedIds.Contains(block.Id)), mode);

    public static string JoinedText(
        IEnumerable<ScreenTextBlock> blocks,
        ScreenTextJoinMode mode) =>
        Join(AssignLineIdsIfNeeded(SortedForReading(Deduplicated(blocks))), mode);

    public void Toggle(string id)
    {
        if (!SelectedIds.Remove(id))
        {
            SelectedIds.Add(id);
            AnchorId = id;
        }
    }

    public void Select(string id)
    {
        SelectedIds = new HashSet<string>([id], StringComparer.Ordinal);
        AnchorId = id;
    }

    public void Extend(string id)
    {
        var anchor = AnchorId ?? SelectedIds.FirstOrDefault();
        if (anchor is null)
        {
            Select(id);
            return;
        }

        var startIndex = IndexOf(anchor);
        var endIndex = IndexOf(id);
        if (startIndex < 0 || endIndex < 0)
        {
            return;
        }

        SelectIndexRange(startIndex, endIndex);
        AnchorId = anchor;
    }

    public void SelectLine(string id)
    {
        var block = Blocks.FirstOrDefault(item => item.Id == id);
        if (block is null)
        {
            return;
        }

        var lineBlocks = Blocks
            .Where(item => item.LineId == block.LineId && item.DisplayId == block.DisplayId)
            .ToArray();
        SelectedIds = lineBlocks.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        AnchorId = lineBlocks.FirstOrDefault()?.Id;
    }

    public void SelectAll(uint displayId)
    {
        var onDisplay = Blocks.Where(block => block.DisplayId == displayId).ToArray();
        SelectedIds = onDisplay.Select(block => block.Id).ToHashSet(StringComparer.Ordinal);
        AnchorId = onDisplay.FirstOrDefault()?.Id;
    }

    public void ClearSelection()
    {
        SelectedIds.Clear();
        AnchorId = null;
    }

    public void SelectBlocks(RectD selectionBounds)
    {
        var bounds = selectionBounds.Standardized;
        var inRange = Blocks.Where(block => bounds.Contains(block.Center)).ToArray();
        SelectedIds = inRange.Select(block => block.Id).ToHashSet(StringComparer.Ordinal);
        AnchorId = inRange.FirstOrDefault()?.Id;
    }

    public void SelectRange(PointD startPoint, PointD endPoint)
    {
        if (Blocks.Count == 0)
        {
            return;
        }

        var start = NearestBlock(startPoint);
        var end = NearestBlock(endPoint);
        if (start is null || end is null)
        {
            return;
        }

        SelectIndexRange(IndexOf(start.Id), IndexOf(end.Id));
        AnchorId = start.Id;
    }

    public void ExtendRange(PointD endPoint)
    {
        var anchor = AnchorId ?? SelectedIds.FirstOrDefault();
        var end = NearestBlock(endPoint);
        if (anchor is null || end is null)
        {
            return;
        }

        var startIndex = IndexOf(anchor);
        var endIndex = IndexOf(end.Id);
        if (startIndex < 0 || endIndex < 0)
        {
            return;
        }

        SelectIndexRange(startIndex, endIndex);
        AnchorId = anchor;
    }

    public static IReadOnlyList<ScreenTextBlock> Deduplicated(IEnumerable<ScreenTextBlock> blocks)
    {
        var sourcePreferred = blocks.OrderBy(block => block, SourcePreferredComparer.Instance);
        var accepted = new List<ScreenTextBlock>();
        foreach (var block in sourcePreferred)
        {
            if (!accepted.Any(existing => IsDuplicate(existing, block)))
            {
                accepted.Add(block with { });
            }
        }

        return SortedForReading(accepted);
    }

    private static string Join(IEnumerable<ScreenTextBlock> blocks, ScreenTextJoinMode mode)
    {
        var prepared = blocks.ToArray();
        if (prepared.Length == 0)
        {
            return string.Empty;
        }

        if (mode == ScreenTextJoinMode.Spaces)
        {
            return string.Join(" ", prepared.Select(block => block.Text));
        }

        var result = new System.Text.StringBuilder();
        string? previousLineId = null;
        uint? previousDisplayId = null;
        foreach (var block in prepared)
        {
            if (previousLineId is not null)
            {
                result.Append(previousDisplayId == block.DisplayId && previousLineId == block.LineId
                    ? ' '
                    : '\n');
            }

            result.Append(block.Text);
            previousLineId = block.LineId;
            previousDisplayId = block.DisplayId;
        }

        return result.ToString();
    }

    private static IReadOnlyList<ScreenTextBlock> SortedForReading(IEnumerable<ScreenTextBlock> blocks) =>
        blocks.OrderBy(block => block, ReadingComparer.Instance).ToArray();

    private static bool IsDuplicate(ScreenTextBlock existing, ScreenTextBlock candidate)
    {
        if (existing.DisplayId != candidate.DisplayId)
        {
            return false;
        }

        if (existing.Source != candidate.Source)
        {
            return IntersectionOverUnion(existing.Bounds, candidate.Bounds) >= 0.5;
        }

        return Normalize(existing.Text) == Normalize(candidate.Text)
            && OverlapRatio(existing.Bounds, candidate.Bounds) >= 0.6;
    }

    private static string Normalize(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .Trim()
            .ToLowerInvariant();

    private static double OverlapRatio(RectD left, RectD right)
    {
        var intersection = left.Intersection(right);
        var smallerArea = Math.Min(left.Area, right.Area);
        return intersection is null || smallerArea <= 0 ? 0 : intersection.Value.Area / smallerArea;
    }

    private static double IntersectionOverUnion(RectD left, RectD right)
    {
        var intersection = left.Intersection(right);
        if (intersection is null)
        {
            return 0;
        }

        var unionArea = left.Area + right.Area - intersection.Value.Area;
        return unionArea <= 0 ? 0 : intersection.Value.Area / unionArea;
    }

    private static IReadOnlyList<ScreenTextBlock> AssignLineIdsIfNeeded(
        IReadOnlyList<ScreenTextBlock> blocks)
    {
        if (!blocks.Any(block => block.LineId is null))
        {
            return blocks;
        }

        var assigned = new ScreenTextBlock[blocks.Count];
        foreach (var group in blocks.Select((block, index) => (Block: block, Index: index))
                     .GroupBy(item => item.Block.DisplayId))
        {
            var sorted = group.OrderBy(item => item.Block, LineComparer.Instance);
            var lineIndex = 0;
            var lineMinY = double.NegativeInfinity;
            var lineHeight = 0d;
            foreach (var (block, originalIndex) in sorted)
            {
                var updated = block with { };
                if (updated.LineId is null)
                {
                    var threshold = Math.Max(4, Math.Min(block.Bounds.NormalizedHeight, lineHeight) * 0.5);
                    if (Math.Abs(block.Bounds.MinY - lineMinY) > threshold)
                    {
                        lineIndex += 1;
                        lineMinY = block.Bounds.MinY;
                        lineHeight = block.Bounds.NormalizedHeight;
                    }
                    else
                    {
                        lineHeight = (lineHeight + block.Bounds.NormalizedHeight) / 2;
                    }

                    updated.LineId = $"{group.Key}:{lineIndex}";
                }

                assigned[originalIndex] = updated;
            }
        }

        return assigned;
    }

    private ScreenTextBlock? NearestBlock(PointD point) => Blocks.MinBy(block =>
    {
        var deltaX = block.Center.X - point.X;
        var deltaY = block.Center.Y - point.Y;
        return (deltaX * deltaX) + (deltaY * deltaY);
    });

    private int IndexOf(string id)
    {
        for (var index = 0; index < Blocks.Count; index++)
        {
            if (Blocks[index].Id == id)
            {
                return index;
            }
        }

        return -1;
    }

    private void SelectIndexRange(int startIndex, int endIndex)
    {
        var lower = Math.Min(startIndex, endIndex);
        var upper = Math.Max(startIndex, endIndex);
        SelectedIds = Blocks.Skip(lower).Take(upper - lower + 1)
            .Select(block => block.Id)
            .ToHashSet(StringComparer.Ordinal);
    }

    private sealed class ReadingComparer : IComparer<ScreenTextBlock>
    {
        public static ReadingComparer Instance { get; } = new();

        public int Compare(ScreenTextBlock? left, ScreenTextBlock? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return -1;
            if (right is null) return 1;
            if (left.DisplayId != right.DisplayId) return left.DisplayId.CompareTo(right.DisplayId);
            if (Math.Abs(left.Bounds.MinY - right.Bounds.MinY) > 4)
                return left.Bounds.MinY.CompareTo(right.Bounds.MinY);
            if (Math.Abs(left.Bounds.MinX - right.Bounds.MinX) > 4)
                return left.Bounds.MinX.CompareTo(right.Bounds.MinX);
            return string.Compare(left.Id, right.Id, StringComparison.Ordinal);
        }
    }

    private sealed class SourcePreferredComparer : IComparer<ScreenTextBlock>
    {
        public static SourcePreferredComparer Instance { get; } = new();

        public int Compare(ScreenTextBlock? left, ScreenTextBlock? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return -1;
            if (right is null) return 1;
            if (left.Source != right.Source)
                return left.Source == ScreenTextSource.Accessibility ? -1 : 1;
            return ReadingComparer.Instance.Compare(left, right);
        }
    }

    private sealed class LineComparer : IComparer<ScreenTextBlock>
    {
        public static LineComparer Instance { get; } = new();

        public int Compare(ScreenTextBlock? left, ScreenTextBlock? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return -1;
            if (right is null) return 1;
            if (Math.Abs(left.Bounds.MinY - right.Bounds.MinY) > 4)
                return left.Bounds.MinY.CompareTo(right.Bounds.MinY);
            return left.Bounds.MinX.CompareTo(right.Bounds.MinX);
        }
    }
}
