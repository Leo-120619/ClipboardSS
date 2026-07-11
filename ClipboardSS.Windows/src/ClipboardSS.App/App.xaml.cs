using System.Windows;
using ClipboardSS.App.Capture;
using ClipboardSS.App.Net;
using ClipboardSS.App.Pairing;
using ClipboardSS.App.Security;
using ClipboardSS.App.Settings;
using ClipboardSS.App.Tray;
using ClipboardSS.App.UI;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Storage;
using ClipboardSS.Core.Sync;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace ClipboardSS.App;

public partial class App : System.Windows.Application
{
    private AppInstance? _primaryInstance;
    private Mutex? _fallbackMutex;
    private SettingsStore? _settings;
    private ClipboardInterop? _clipboard;
    private AppModel? _model;
    private TcpClipServer? _server;
    private TrayController? _tray;
    private HotKeyManager? _hotKeys;
    private PasteInjector? _pasteInjector;
    private ScreenshotCaptureService? _screenshotCapture;
    private OcrService? _ocrService;
    private ScreenTextCaptureService? _screenTextCapture;
    private ScreenTextOverlayController? _screenTextOverlay;
    private MainWindow? _mainWindow;
    private DevicesWindow? _devicesWindow;
    private PreferencesWindow? _preferencesWindow;
    private ShareActivationCoordinator? _shareCoordinator;

    protected override async void OnStartup(StartupEventArgs args)
    {
        base.OnStartup(args);
        AppActivationArguments? activation;
        try
        {
            activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            var instance = AppInstance.FindOrRegisterForKey("ClipboardSS.Windows.Singleton");
            if (!instance.IsCurrent)
            {
                await instance.RedirectActivationToAsync(activation);
                Shutdown();
                return;
            }
            _primaryInstance = instance;
            _primaryInstance.Activated += PrimaryInstance_OnActivated;
        }
        catch
        {
            // Unpackaged development builds do not receive Share Target activation.
            activation = null;
            _fallbackMutex = new Mutex(true, @"Local\ClipboardSS.Windows.Singleton", out var createdNew);
            if (!createdNew)
            {
                MessageBox.Show(
                    "ClipboardSS is already running. Look for it in the system tray.",
                    "ClipboardSS",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                Shutdown();
                return;
            }
        }

        Wpf.Ui.Appearance.ApplicationThemeManager.ApplySystemTheme();

        try
        {
            ComposeAndStart();
            await HandleActivationAsync(activation);
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                $"ClipboardSS could not start.\n\n{exception.Message}",
                "ClipboardSS",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs args)
    {
        _tray?.Dispose();
        _screenTextOverlay?.Dispose();
        _hotKeys?.Dispose();
        _model?.Dispose();
        if (_server is not null) _server.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _clipboard?.Dispose();
        if (_primaryInstance is not null) _primaryInstance.Activated -= PrimaryInstance_OnActivated;
        if (_fallbackMutex is not null)
        {
            try { _fallbackMutex.ReleaseMutex(); }
            catch (ApplicationException) { }
            _fallbackMutex.Dispose();
        }
        base.OnExit(args);
    }

    private void ComposeAndStart()
    {
        _settings = new SettingsStore(SettingsStore.ResolveStorageDirectory());
        var identity = new DeviceIdentity(
            _settings.Current.DeviceId,
            _settings.Current.DeviceName);
        var store = new ClipStore(_settings.StorageDirectory);
        _clipboard = new ClipboardInterop();
        var pairKeys = new DpapiPairKeyStorage(_settings.StorageDirectory);
        var pairedStore = new PairedDeviceStore(
            Path.Combine(_settings.StorageDirectory, "paired-devices.json"),
            pairKeys);
        var transport = new TcpPeerTransport();
        var pairing = new PairingCoordinator(identity, pairedStore, transport);
        var mdns = new MdnsService(identity);
        var sweeper = new SubnetSweeper();
        var sender = new ClipSender(identity, pairedStore, transport, _settings.StorageDirectory);
        var fileSender = new FileSender(identity, pairedStore, transport);
        var fileReceiver = new FileReceiver(Path.Combine(_settings.StorageDirectory, "Transfers"),
            () => ResolveReceiveDirectory(_settings.Current));
        _model = new AppModel(store, _clipboard, pairing, sender, mdns, sweeper, fileSender, fileReceiver, _settings);
        _shareCoordinator = new ShareActivationCoordinator(
            _model,
            () => _mainWindow,
            () => _devicesWindow?.ShowFromTray(_mainWindow));
        _server = new TcpClipServer(new ClipServerRouter(identity, _model));
        _hotKeys = new HotKeyManager();
        _pasteInjector = new PasteInjector();
        _screenshotCapture = new ScreenshotCaptureService();
        _ocrService = new OcrService();
        _screenTextCapture = new ScreenTextCaptureService(_screenshotCapture, _ocrService);
        _screenTextOverlay = new ScreenTextOverlayController();

        _mainWindow = new MainWindow(_model, _settings);
        _devicesWindow = new DevicesWindow(_model);
        var hotKeyResult = _hotKeys.Apply(_settings.Current);
        _preferencesWindow = new PreferencesWindow(_settings, _hotKeys);
        _mainWindow.DevicesRequested += (_, _) => _devicesWindow.ShowFromTray(_mainWindow);
        _mainWindow.PreferencesRequested += (_, _) => _preferencesWindow.ShowFromTray(_mainWindow);
        _mainWindow.ScreenTextRequested += (_, _) => _ = StartScreenTextSelectionAsync();
        _mainWindow.ScreenshotRequested += (_, _) => _ = StartScreenshotCaptureAsync();
        _hotKeys.ClipboardPressed += (_, _) =>
        {
            _ = _pasteInjector.RememberForegroundWindow();
            _mainWindow.ToggleFromHotKey();
        };
        _hotKeys.ScreenshotPressed += (_, _) => _ = StartScreenshotCaptureAsync();
        _hotKeys.ScreenTextPressed += (_, _) => _ = StartScreenTextSelectionAsync();
        _model.PasteRequested += request => _ = PerformPasteAsync(request);
        _tray = new TrayController(
            _model,
            _settings,
            OpenFromTray,
            () => _devicesWindow.ShowFromTray(_mainWindow),
            () => _preferencesWindow.ShowFromTray(_mainWindow),
            () => _ = StartScreenTextSelectionAsync(),
            ShutdownFromTray);

        try
        {
            _ = SynchronizeStartupRegistrationAsync(_settings.Current.LaunchAtLogin);
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                $"ClipboardSS started, but could not update Start at login.\n\n{exception.Message}",
                "ClipboardSS",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

        try
        {
            _server.Start();
        }
        catch (InvalidOperationException exception)
        {
            MessageBox.Show(
                exception.Message,
                "ClipboardSS sync unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

        _model.Start();
        MainWindow = _mainWindow;
        _ = _pasteInjector.RememberForegroundWindow();
        _mainWindow.Show();
        if (!hotKeyResult.Succeeded)
        {
            var failure = hotKeyResult.Failures[0];
            MessageBox.Show(
                $"ClipboardSS started, but could not register {failure.Shortcut.DisplayName}.\n\n{failure.Message}\n\nChoose another shortcut in Preferences.",
                "ClipboardSS shortcut conflict",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void OpenFromTray()
    {
        _ = _pasteInjector?.RememberForegroundWindow();
        _mainWindow?.ShowFromTray();
    }

    private void PrimaryInstance_OnActivated(object? sender, AppActivationArguments args) =>
        Dispatcher.InvokeAsync(() => HandleActivationAsync(args));

    private async Task HandleActivationAsync(AppActivationArguments? args)
    {
        if (args is null) return;
        if (args.Kind == ExtendedActivationKind.ShareTarget &&
            args.Data is ShareTargetActivatedEventArgs shareArgs &&
            _shareCoordinator is not null)
        {
            await _shareCoordinator.HandleAsync(shareArgs.ShareOperation);
            return;
        }
        if (_mainWindow is not null && args.Kind != ExtendedActivationKind.Launch)
            _mainWindow.ShowFromTray();
    }

    private async Task SynchronizeStartupRegistrationAsync(bool requested)
    {
        try
        {
            var result = await StartupRegistration.SetEnabledAsync(requested);
            _settings?.Update(current => current with { LaunchAtLogin = result.IsEnabled });
            if (result.WasDeniedByUser)
            {
                MessageBox.Show(
                    "Windows denied ClipboardSS permission to start at sign-in. You can change this in Windows Startup Apps settings.",
                    "ClipboardSS start at login",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                $"ClipboardSS started, but could not update Start at login.\n\n{exception.Message}",
                "ClipboardSS",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async Task PerformPasteAsync(PasteRequest request)
    {
        if (_pasteInjector is null || _mainWindow is null || _model is null) return;
        try
        {
            await _pasteInjector.PasteAsync(_mainWindow, request);
        }
        catch (Exception exception)
        {
            _model.ReportError(exception.Message);
            _mainWindow.ShowFromTray();
        }
    }

    private async Task StartScreenshotCaptureAsync()
    {
        if (_screenshotCapture is null || _ocrService is null || _model is null || _mainWindow is null) return;
        if (_mainWindow.IsVisible) _mainWindow.HideToTray();
        byte[] png;
        try
        {
            png = await _screenshotCapture.CaptureRegionAsync();
        }
        catch (ScreenCaptureCancelledException)
        {
            return;
        }
        catch (Exception exception)
        {
            _model.ReportError($"Screenshot capture failed: {exception.Message}");
            return;
        }

        _model.AddScreenshot(png);
        IReadOnlyList<ClipboardSS.Core.Selection.OcrTextBlock> blocks = [];
        string? ocrMessage = null;
        try
        {
            blocks = await _ocrService.RecognizeLinesAsync(png);
        }
        catch (OcrUnavailableException exception)
        {
            ocrMessage = exception.Message;
        }
        catch (Exception exception)
        {
            ocrMessage = $"OCR could not read this screenshot: {exception.Message}";
        }

        var review = new ScreenshotReviewWindow(_model, png, blocks, ocrMessage);
        review.Show();
    }

    private async Task StartScreenTextSelectionAsync()
    {
        if (_screenTextCapture is null || _screenTextOverlay is null || _model is null || _mainWindow is null) return;
        if (_mainWindow.IsVisible) _mainWindow.HideToTray();
        try
        {
            var capture = await _screenTextCapture.CaptureAllDisplaysAsync();
            _screenTextOverlay.Present(capture, _model.CopyText);
        }
        catch (OcrUnavailableException exception)
        {
            _model.ReportError(exception.Message);
            _mainWindow.ShowFromTray();
        }
        catch (Exception exception)
        {
            _model.ReportError($"Screen-text selection failed: {exception.Message}");
            _mainWindow.ShowFromTray();
        }
    }

    private void ShutdownFromTray()
    {
        _devicesWindow?.CloseForExit();
        _preferencesWindow?.CloseForExit();
        _mainWindow?.CloseForExit();
        Shutdown();
    }

    private static string ResolveReceiveDirectory(AppSettings settings)
    {
        if (settings.ReceiveDestinationMode == ReceiveDestinationMode.Folder &&
            !string.IsNullOrWhiteSpace(settings.ReceiveDestinationPath) &&
            Directory.Exists(settings.ReceiveDestinationPath))
            return settings.ReceiveDestinationPath;

        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}
