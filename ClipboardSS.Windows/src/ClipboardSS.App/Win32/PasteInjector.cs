using System.ComponentModel;
using System.Runtime.InteropServices;
using ClipboardSS.App.UI;

namespace ClipboardSS.App.Win32;

public sealed class PasteInjector
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    private const int SwRestore = 9;
    private readonly object _gate = new();
    private IntPtr _targetWindow;

    public bool RememberForegroundWindow()
    {
        var candidate = NativeMethods.GetForegroundWindow();
        if (candidate == IntPtr.Zero || !NativeMethods.IsWindow(candidate)) return false;
        _ = NativeMethods.GetWindowThreadProcessId(candidate, out var processId);
        if (processId == (uint)Environment.ProcessId) return false;
        lock (_gate) _targetWindow = candidate;
        return true;
    }

    public async Task PasteAsync(
        MainWindow window,
        PasteRequest request,
        CancellationToken cancellationToken = default)
    {
        IntPtr target;
        lock (_gate) target = _targetWindow;
        if (target == IntPtr.Zero || !NativeMethods.IsWindow(target))
        {
            throw new InvalidOperationException(
                "ClipboardSS no longer has a valid target window. Focus the destination app, then open ClipboardSS with its shortcut and try again.");
        }

        await window.Dispatcher.InvokeAsync(window.HideToTray);
        try
        {
            _ = NativeMethods.ShowWindowAsync(target, SwRestore);
            if (NativeMethods.GetForegroundWindow() != target) _ = NativeMethods.SetForegroundWindow(target);
            await Task.Delay(TimeSpan.FromMilliseconds(150), cancellationToken);
            if (NativeMethods.GetForegroundWindow() != target)
            {
                throw new InvalidOperationException(
                    "Windows would not return focus to the destination app. Focus it manually, reopen ClipboardSS with the hotkey, and try again.");
            }

            var inputs = new[]
            {
                KeyboardInput(VkControl, keyUp: false),
                KeyboardInput(VkV, keyUp: false),
                KeyboardInput(VkV, keyUp: true),
                KeyboardInput(VkControl, keyUp: true),
            };
            var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
            if (sent != (uint)inputs.Length)
            {
                var error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    "Windows blocked the paste. ClipboardSS cannot inject input into an elevated application; run both apps at the same privilege level.");
            }
        }
        finally
        {
            if (request.Mode == PasteMode.KeepWindowOpen)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(150), CancellationToken.None);
                await window.Dispatcher.InvokeAsync(window.ShowFromTray);
            }
        }
    }

    private static Input KeyboardInput(ushort virtualKey, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Data = new InputUnion
        {
            Keyboard = new KeyboardInputData
            {
                VirtualKey = virtualKey,
                Flags = keyUp ? KeyEventKeyUp : 0,
            },
        },
    };

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInputData Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }
}
