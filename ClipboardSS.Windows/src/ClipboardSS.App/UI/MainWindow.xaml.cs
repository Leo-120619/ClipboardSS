using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using ClipboardSS.App.Settings;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Models;

namespace ClipboardSS.App.UI;

public partial class MainWindow : Wpf.Ui.Controls.FluentWindow
{
    private readonly AppModel _model;
    private readonly SettingsStore _settings;
    private readonly DispatcherTimer _pollTimer;
    private ClipFilter _filter = ClipFilter.All;
    private bool _allowClose;
    private bool _initialized;
    private IntPtr _windowHandle;
    private string? _projectionKey;

    public MainWindow(AppModel model, SettingsStore settings)
    {
        InitializeComponent();
        _model = model;
        _settings = settings;
        DataContext = model;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => RestoreFrame();
        Closing += OnClosing;
        PreviewKeyDown += OnPreviewKeyDown;
        _model.StateChanged += (_, _) => Dispatcher.Invoke(RefreshView);
        _model.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppModel.LastError)) Dispatcher.Invoke(RefreshError);
        };
        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(750) };
        _pollTimer.Tick += (_, _) =>
        {
            if (!_allowClose) _model.Refresh();
        };
        _pollTimer.Start();
        _initialized = true;
        RefreshView();
    }

    public event EventHandler? DevicesRequested;
    public event EventHandler? ScreenTextRequested;
    public event EventHandler? ScreenshotRequested;
    public event EventHandler? PreferencesRequested;

    public void ShowFromTray()
    {
        SetNoActivate(true);
        _model.Refresh();
        if (!IsVisible) Show();
        Topmost = false;
        Topmost = true;
    }

    public void ToggleFromHotKey()
    {
        if (IsVisible) HideToTray();
        else ShowFromTray();
    }

    public void HideToTray()
    {
        Keyboard.ClearFocus();
        SetNoActivate(true);
        SaveFrame();
        Hide();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        _pollTimer.Stop();
        SaveFrame();
        Close();
    }

    private void RefreshView()
    {
        var clips = _model.Store.Clips(SearchBox.Text ?? string.Empty, _filter);
        var projectionKey = string.Join('|', clips.Select(clip =>
            $"{clip.Id:N}:{clip.CreatedAt.UtcDateTime.Ticks}:{clip.IsPinned}:{clip.PreviewText}:{clip.ImagePath}"))
            + $"|{SearchBox.Text}|{_filter}";
        if (_projectionKey != projectionKey)
        {
            _projectionKey = projectionKey;
            var entries = clips.Select((clip, index) => new ClipListEntry(
                index == 0 ? "LATEST" : "HISTORY",
                clip,
                index == 0)).ToArray();
            var view = new ListCollectionView(entries);
            view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(ClipListEntry.Section)));
            ClipList.ItemsSource = view;
            ClipList.Visibility = entries.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            EmptyState.Visibility = entries.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        StatusText.Text = $"{_model.Clips.Count} clips · {_model.PairedDevices.Count} paired"
            + (_model.IsSyncPaused ? " · sync paused" : string.Empty);
        RefreshError();
    }

    private void RefreshError()
    {
        ErrorText.Text = _model.LastError ?? string.Empty;
        ErrorBanner.Visibility = string.IsNullOrWhiteSpace(_model.LastError)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnSourceInitialized(object? sender, EventArgs args)
    {
        _windowHandle = new WindowInteropHelper(this).Handle;
        var style = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle);
        NativeMethods.SetWindowLong(
            _windowHandle,
            NativeMethods.GwlExStyle,
            style | NativeMethods.WsExToolWindow | NativeMethods.WsExNoActivate);
    }

    private void SetNoActivate(bool noActivate)
    {
        if (_windowHandle == IntPtr.Zero) return;
        var style = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle);
        var next = noActivate
            ? style | NativeMethods.WsExNoActivate
            : style & ~NativeMethods.WsExNoActivate;
        NativeMethods.SetWindowLong(_windowHandle, NativeMethods.GwlExStyle, next);
    }

    private void SearchBox_OnPreviewMouseDown(object sender, MouseButtonEventArgs args)
    {
        SetNoActivate(false);
        Dispatcher.BeginInvoke(() =>
        {
            Activate();
            SearchBox.Focus();
        }, DispatcherPriority.Input);
    }

    private void SearchBox_OnLostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs args) =>
        SetNoActivate(true);

    private void SearchBox_OnTextChanged(object sender, TextChangedEventArgs args)
    {
        if (_initialized) RefreshView();
    }

    private void Filter_OnChecked(object sender, RoutedEventArgs args)
    {
        if (sender is RadioButton { Tag: string tag } && Enum.TryParse<ClipFilter>(tag, out var filter))
            _filter = filter;
        if (IsLoaded) RefreshView();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key == Key.Escape)
        {
            args.Handled = true;
            Keyboard.ClearFocus();
            SetNoActivate(true);
            HideToTray();
        }
    }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        HideToTray();
    }

    private void RestoreFrame()
    {
        var frame = _settings.Current.MainWindowFrame;
        if (frame is null)
        {
            Left = SystemParameters.WorkArea.Left + ((SystemParameters.WorkArea.Width - ActualWidth) / 2);
            Top = SystemParameters.WorkArea.Top + ((SystemParameters.WorkArea.Height - ActualHeight) / 2);
            return;
        }
        Width = Math.Max(MinWidth, frame.Width);
        Height = Math.Max(MinHeight, frame.Height);
        Left = Math.Clamp(frame.Left, SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100);
        Top = Math.Clamp(frame.Top, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 100);
    }

    private void SaveFrame()
    {
        if (!IsLoaded || WindowState == WindowState.Minimized) return;
        var bounds = RestoreBounds;
        _settings.Update(current => current with
        {
            MainWindowFrame = new WindowFrame(bounds.Left, bounds.Top, bounds.Width, bounds.Height),
        });
    }

    private void Devices_OnClick(object sender, RoutedEventArgs args) => DevicesRequested?.Invoke(this, EventArgs.Empty);
    private void Window_OnDragOver(object sender, DragEventArgs args)
    {
        args.Effects = args.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        args.Handled = true;
    }

    private async void Window_OnDrop(object sender, DragEventArgs args)
    {
        if (args.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } paths || !File.Exists(paths[0])) return;
        var devices = _model.PairedDevices.Where(device => !string.IsNullOrWhiteSpace(device.Host)).ToArray();
        if (devices.Length != 1)
        {
            _model.ReportError(devices.Length == 0 ? "Pair a reachable device before sending a file." : "Choose Send file next to a device in Devices.");
            if (devices.Length > 1) DevicesRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        await _model.SendFileAsync(paths[0], devices[0].Id);
    }
    private void ScreenText_OnClick(object sender, RoutedEventArgs args) => ScreenTextRequested?.Invoke(this, EventArgs.Empty);
    private void Screenshot_OnClick(object sender, RoutedEventArgs args) => ScreenshotRequested?.Invoke(this, EventArgs.Empty);
    private void Preferences_OnClick(object sender, RoutedEventArgs args) => PreferencesRequested?.Invoke(this, EventArgs.Empty);
    private void Card_OnCopyRequested(ClipItem clip) => _model.Copy(clip);
    private void Card_OnPinRequested(ClipItem clip) => _model.SetPinned(clip, !clip.IsPinned);
    private void Card_OnDeleteRequested(ClipItem clip) => _model.Delete(clip);
    private void Card_OnSinglePasteRequested(ClipItem clip) => _model.Paste(clip, PasteMode.KeepWindowOpen);
    private void Card_OnDoublePasteRequested(ClipItem clip) => _model.Paste(clip, PasteMode.CloseWindow);

    private sealed record ClipListEntry(string Section, ClipItem Clip, bool IsProminent);
}
