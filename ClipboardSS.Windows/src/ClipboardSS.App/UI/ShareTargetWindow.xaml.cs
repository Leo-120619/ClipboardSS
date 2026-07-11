using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace ClipboardSS.App.UI;

public partial class ShareTargetWindow : Wpf.Ui.Controls.FluentWindow
{
    private readonly AppModel _model;
    private readonly TaskCompletionSource<Guid?> _choice = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _finishing;

    public ShareTargetWindow(AppModel model, IReadOnlyList<string> paths)
    {
        InitializeComponent();
        _model = model;
        FilesText.Text = paths.Count == 1
            ? $"{Path.GetFileName(paths[0])}"
            : $"{paths.Count} files: {string.Join(", ", paths.Select(Path.GetFileName))}";
        _model.StateChanged += Model_OnStateChanged;
        Closing += OnClosing;
        RefreshTargets();
    }

    public event EventHandler? PairingRequested;

    public Task<Guid?> ChooseAsync()
    {
        Show();
        Activate();
        return _choice.Task;
    }

    private void Model_OnStateChanged(object? sender, EventArgs args) => Dispatcher.Invoke(RefreshTargets);

    private void RefreshTargets()
    {
        var targets = AppModel.ComposeSendTargets(_model.VisiblePeers, _model.PairedDevices);
        TargetList.ItemsSource = targets;
        EmptyPanel.Visibility = targets.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Target_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: Guid id }) Finish(id);
    }

    private void Pair_OnClick(object sender, RoutedEventArgs args) => PairingRequested?.Invoke(this, EventArgs.Empty);
    private void Cancel_OnClick(object sender, RoutedEventArgs args) => Finish(null);

    private void Finish(Guid? id)
    {
        if (_finishing) return;
        _finishing = true;
        _model.StateChanged -= Model_OnStateChanged;
        _choice.TrySetResult(id);
        Close();
    }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (!_finishing)
        {
            _finishing = true;
            _model.StateChanged -= Model_OnStateChanged;
            _choice.TrySetResult(null);
        }
    }
}
