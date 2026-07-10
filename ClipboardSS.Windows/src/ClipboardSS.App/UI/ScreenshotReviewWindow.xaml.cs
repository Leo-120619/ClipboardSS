using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using ClipboardSS.App.Capture;
using ClipboardSS.Core.Selection;

namespace ClipboardSS.App.UI;

public partial class ScreenshotReviewWindow : Window
{
    private readonly AppModel _model;
    private readonly OcrSelectionState _selection;

    public ScreenshotReviewWindow(
        AppModel model,
        byte[] pngData,
        IReadOnlyList<OcrTextBlock> blocks,
        string? ocrMessage = null)
    {
        InitializeComponent();
        _model = model;
        _selection = new OcrSelectionState(blocks);
        ScreenshotImage.Source = LoadImage(pngData);
        BlocksList.ItemsSource = _selection.Blocks;
        EmptyText.Text = ocrMessage ?? (blocks.Count == 0
            ? "No text was detected in this screenshot."
            : "Select one or more lines to copy.");
        LanguageSettingsButton.Visibility = ocrMessage is null ? Visibility.Collapsed : Visibility.Visible;
        RefreshSelection();
    }

    private void BlocksList_OnSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        _selection.SelectedIds.Clear();
        foreach (var block in BlocksList.SelectedItems.OfType<OcrTextBlock>())
            _selection.SelectedIds.Add(block.Id);
        RefreshSelection();
    }

    private void Copy_OnClick(object sender, RoutedEventArgs args)
    {
        if (!_selection.CanCopySelection) return;
        _model.CopyText(_selection.SelectedText);
        Close();
    }

    private void LanguageSettings_OnClick(object sender, RoutedEventArgs args) =>
        Process.Start(new ProcessStartInfo("ms-settings:regionlanguage") { UseShellExecute = true });

    private void RefreshSelection()
    {
        CopyButton.IsEnabled = _selection.CanCopySelection;
        SelectionSummary.Text = _selection.CanCopySelection
            ? $"{_selection.SelectedIds.Count} line(s) selected"
            : "Select text to copy";
    }

    private static BitmapImage LoadImage(byte[] pngData)
    {
        var image = new BitmapImage();
        using var stream = new MemoryStream(pngData, writable: false);
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }
}
