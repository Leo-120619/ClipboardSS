using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using ClipboardSS.App.Settings;

namespace ClipboardSS.App.Win32;

public enum HotKeyKind
{
    Clipboard = 1,
    Screenshot = 2,
    ScreenText = 3,
}

public sealed record HotKeyRegistrationFailure(
    HotKeyKind Kind,
    ShortcutSettings Shortcut,
    string Message);

public sealed record HotKeyRegistrationResult(IReadOnlyList<HotKeyRegistrationFailure> Failures)
{
    public bool Succeeded => Failures.Count == 0;
    public HotKeyRegistrationFailure? For(HotKeyKind kind) => Failures.FirstOrDefault(item => item.Kind == kind);
}

public sealed class HotKeyManager : IDisposable
{
    private const int WmHotKey = 0x0312;
    private readonly HwndSource _messageWindow;
    private readonly HashSet<int> _registeredIds = [];
    private bool _disposed;

    public HotKeyManager()
    {
        _messageWindow = new HwndSource(new HwndSourceParameters("ClipboardSS.HotKeys")
        {
            ParentWindow = new IntPtr(-3),
            WindowStyle = 0,
            Width = 0,
            Height = 0,
        });
        _messageWindow.AddHook(WindowProcedure);
    }

    public event EventHandler? ClipboardPressed;
    public event EventHandler? ScreenshotPressed;
    public event EventHandler? ScreenTextPressed;
    public HotKeyRegistrationResult LastResult { get; private set; } = new([]);

    public HotKeyRegistrationResult Apply(AppSettings settings)
    {
        UnregisterAll();
        var failures = new List<HotKeyRegistrationFailure>();
        Register(HotKeyKind.Clipboard, settings.ClipboardShortcut, failures);
        RegisterOptional(HotKeyKind.Screenshot, settings.ScreenshotShortcut, failures);
        RegisterOptional(HotKeyKind.ScreenText, settings.ScreenTextShortcut, failures);
        LastResult = new HotKeyRegistrationResult(failures);
        return LastResult;
    }

    public void Suspend() => UnregisterAll();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        UnregisterAll();
        _messageWindow.RemoveHook(WindowProcedure);
        _messageWindow.Dispose();
    }

    private void RegisterOptional(
        HotKeyKind kind,
        ShortcutSettings? shortcut,
        List<HotKeyRegistrationFailure> failures)
    {
        if (shortcut is not null) Register(kind, shortcut, failures);
    }

    private void Register(
        HotKeyKind kind,
        ShortcutSettings shortcut,
        List<HotKeyRegistrationFailure> failures)
    {
        if (!shortcut.IsValid)
        {
            failures.Add(new HotKeyRegistrationFailure(
                kind,
                shortcut,
                $"{shortcut.DisplayName} must include Ctrl, Alt, Shift, or Windows plus a non-modifier key."));
            return;
        }

        var id = (int)kind;
        if (NativeMethods.RegisterHotKey(
                _messageWindow.Handle,
                id,
                (uint)shortcut.ModifierKeys | NativeMethods.ModNoRepeat,
                shortcut.VirtualKey))
        {
            _registeredIds.Add(id);
            return;
        }

        var error = Marshal.GetLastWin32Error();
        var detail = error == 1409
            ? "That shortcut is already registered by Windows or another application."
            : new Win32Exception(error).Message;
        failures.Add(new HotKeyRegistrationFailure(kind, shortcut, detail));
    }

    private void UnregisterAll()
    {
        foreach (var id in _registeredIds) _ = NativeMethods.UnregisterHotKey(_messageWindow.Handle, id);
        _registeredIds.Clear();
    }

    private IntPtr WindowProcedure(
        IntPtr window,
        int message,
        IntPtr wParam,
        IntPtr lParam,
        ref bool handled)
    {
        if (message != WmHotKey) return IntPtr.Zero;
        handled = true;
        switch ((HotKeyKind)wParam.ToInt32())
        {
            case HotKeyKind.Clipboard:
                ClipboardPressed?.Invoke(this, EventArgs.Empty);
                break;
            case HotKeyKind.Screenshot:
                ScreenshotPressed?.Invoke(this, EventArgs.Empty);
                break;
            case HotKeyKind.ScreenText:
                ScreenTextPressed?.Invoke(this, EventArgs.Empty);
                break;
        }
        return IntPtr.Zero;
    }
}
