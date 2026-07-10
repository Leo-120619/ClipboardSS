using System.ComponentModel;
using System.Windows;
using ClipboardSS.App.Settings;
using ClipboardSS.App.Win32;

namespace ClipboardSS.App.UI;

public partial class PreferencesWindow : Wpf.Ui.Controls.FluentWindow
{
    private readonly SettingsStore _settings;
    private readonly HotKeyManager _hotKeys;
    private bool _allowClose;

    public PreferencesWindow(SettingsStore settings, HotKeyManager hotKeys)
    {
        InitializeComponent();
        _settings = settings;
        _hotKeys = hotKeys;
        StoragePathText.Text = settings.StorageDirectory;
        ClipboardRecorder.RecordingMessageChanged += ShowRecorderMessage;
        ScreenshotRecorder.RecordingMessageChanged += ShowRecorderMessage;
        ScreenTextRecorder.RecordingMessageChanged += ShowRecorderMessage;
        ClipboardRecorder.RecordingStateChanged += RecordingStateChanged;
        ScreenshotRecorder.RecordingStateChanged += RecordingStateChanged;
        ScreenTextRecorder.RecordingStateChanged += RecordingStateChanged;
        Closing += OnClosing;
        SyncControls();
    }

    public void ShowFromTray(Window? owner = null)
    {
        Owner = owner?.IsVisible == true ? owner : null;
        SyncControls();
        Show();
        Activate();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        Close();
    }

    private void ClipboardShortcut_OnRecorded(object sender, ShortcutRecordedEventArgs args) =>
        ApplyShortcutChange(
            HotKeyKind.Clipboard,
            current => current with { ClipboardShortcut = args.Shortcut });

    private void ScreenshotShortcut_OnRecorded(object sender, ShortcutRecordedEventArgs args) =>
        ApplyShortcutChange(
            HotKeyKind.Screenshot,
            current => current with { ScreenshotShortcut = args.Shortcut });

    private void ScreenTextShortcut_OnRecorded(object sender, ShortcutRecordedEventArgs args) =>
        ApplyShortcutChange(
            HotKeyKind.ScreenText,
            current => current with { ScreenTextShortcut = args.Shortcut });

    private void ClearScreenshot_OnClick(object sender, RoutedEventArgs args) =>
        ApplyShortcutChange(
            HotKeyKind.Screenshot,
            current => current with { ScreenshotShortcut = null });

    private void ClearScreenText_OnClick(object sender, RoutedEventArgs args) =>
        ApplyShortcutChange(
            HotKeyKind.ScreenText,
            current => current with { ScreenTextShortcut = null });

    private void ApplyShortcutChange(HotKeyKind kind, Func<AppSettings, AppSettings> update)
    {
        var previous = _settings.Current;
        var candidate = update(previous);
        var duplicate = ShortcutValidation.FindDuplicate(candidate);
        if (duplicate is not null)
        {
            ShowShortcutError($"{duplicate} use the same shortcut. Choose a different combination.");
            SyncControls();
            return;
        }

        var result = _hotKeys.Apply(candidate);
        if (!result.Succeeded)
        {
            _ = _hotKeys.Apply(previous);
            var failure = result.For(kind) ?? result.Failures[0];
            ShowShortcutError($"Could not register {failure.Shortcut.DisplayName}. {failure.Message}");
            SyncControls();
            return;
        }

        try
        {
            _settings.Update(_ => candidate);
            ShowShortcutError(null);
            SyncControls();
        }
        catch (Exception exception)
        {
            _ = _hotKeys.Apply(previous);
            ShowShortcutError($"The shortcut worked but could not be saved: {exception.Message}");
            SyncControls();
        }
    }

    private async void LaunchAtLogin_OnClick(object sender, RoutedEventArgs args)
    {
        var enabled = LaunchAtLoginCheck.IsChecked == true;
        try
        {
            LaunchAtLoginCheck.IsEnabled = false;
            var result = await StartupRegistration.SetEnabledAsync(enabled);
            _settings.Update(current => current with { LaunchAtLogin = result.IsEnabled });
            LaunchAtLoginCheck.IsChecked = result.IsEnabled;
            ErrorText.Text = result.WasDeniedByUser
                ? "Windows denied the request to start ClipboardSS at sign-in. You can change this in Windows Startup Apps settings."
                : string.Empty;
        }
        catch (Exception exception)
        {
            ErrorText.Text = exception.Message;
            LaunchAtLoginCheck.IsChecked = _settings.Current.LaunchAtLogin;
        }
        finally
        {
            LaunchAtLoginCheck.IsEnabled = true;
        }
    }

    private void SyncControls()
    {
        var current = _settings.Current;
        LaunchAtLoginCheck.IsChecked = current.LaunchAtLogin;
        ClipboardRecorder.Shortcut = current.ClipboardShortcut;
        ScreenshotRecorder.Shortcut = current.ScreenshotShortcut;
        ScreenTextRecorder.Shortcut = current.ScreenTextShortcut;
        if (!_hotKeys.LastResult.Succeeded)
        {
            var failure = _hotKeys.LastResult.Failures[0];
            ShowShortcutError($"Could not register {failure.Shortcut.DisplayName}. {failure.Message}");
        }
    }

    private void ShowRecorderMessage(string? message)
    {
        ShowShortcutError(message);
    }

    private void RecordingStateChanged(bool isRecording)
    {
        if (isRecording) _hotKeys.Suspend();
        else _ = _hotKeys.Apply(_settings.Current);
    }

    private void ShowShortcutError(string? message)
    {
        ShortcutErrorText.Text = message ?? string.Empty;
        ShortcutErrorBorder.Visibility = string.IsNullOrWhiteSpace(message)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        _ = _hotKeys.Apply(_settings.Current);
        Hide();
    }
}
