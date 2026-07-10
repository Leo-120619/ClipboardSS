namespace ClipboardSS.Core.Selection;

public sealed record OcrTextBlock(string Id, string Text);

public sealed class OcrSelectionState
{
    public OcrSelectionState(
        IEnumerable<OcrTextBlock> blocks,
        IEnumerable<string>? selectedIds = null)
    {
        Blocks = blocks.ToArray();
        SelectedIds = selectedIds?.ToHashSet(StringComparer.Ordinal)
            ?? new HashSet<string>(StringComparer.Ordinal);
    }

    public IReadOnlyList<OcrTextBlock> Blocks { get; }
    public HashSet<string> SelectedIds { get; }
    public bool CanCopySelection => SelectedIds.Count > 0;
    public string SelectedText => string.Join(
        "\n",
        Blocks.Where(block => SelectedIds.Contains(block.Id)).Select(block => block.Text));

    public void Toggle(string id)
    {
        if (!SelectedIds.Remove(id))
        {
            SelectedIds.Add(id);
        }
    }
}
