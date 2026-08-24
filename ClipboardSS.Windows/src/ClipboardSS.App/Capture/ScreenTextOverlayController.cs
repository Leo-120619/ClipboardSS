using ClipboardSS.Core.Selection;

namespace ClipboardSS.App.Capture;

public sealed class ScreenTextOverlayController : IDisposable
{
    private readonly List<ScreenTextOverlayWindow> _windows = [];
    private ScreenTextSelectionState? _selection;
    private Action<string>? _copyHandler;

    public void Present(ScreenTextCapture capture, Action<string> copyHandler)
    {
        Dismiss();
        _selection = new ScreenTextSelectionState(capture.Blocks);
        _copyHandler = copyHandler;
        foreach (var snapshot in capture.Snapshots.Values)
        {
            var window = new ScreenTextOverlayWindow(snapshot, _selection, SelectionChanged, CopySelected, Dismiss);
            _windows.Add(window);
            window.Show();
        }
    }

    public void Dismiss()
    {
        foreach (var window in _windows.ToArray()) window.CloseFromController();
        _windows.Clear();
        _selection = null;
        _copyHandler = null;
    }

    public void Dispose() => Dismiss();

    private void SelectionChanged()
    {
        foreach (var window in _windows) window.RefreshSelection();
    }

    private void CopySelected()
    {
        if (_selection is not { CanCopySelection: true }) return;
        var text = _selection.SelectedText;
        var copyHandler = _copyHandler;
        Dismiss();
        copyHandler?.Invoke(text);
    }
}
