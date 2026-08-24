using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Win32;

public sealed class ClipboardInterop : IPasteboardClient, IDisposable
{
    private const int WmClipboardUpdate = 0x031d;
    private readonly HwndSource _messageWindow;
    private readonly uint _pngFormat;
    private bool _disposed;

    public ClipboardInterop()
    {
        _messageWindow = new HwndSource(new HwndSourceParameters("ClipboardSS.ClipboardListener")
        {
            ParentWindow = new IntPtr(-3),
            WindowStyle = 0,
            Width = 0,
            Height = 0,
        });
        _messageWindow.AddHook(WindowProcedure);
        if (!NativeMethods.AddClipboardFormatListener(_messageWindow.Handle))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        _pngFormat = NativeMethods.RegisterClipboardFormat("PNG");
    }

    public event EventHandler? Changed;

    public long CurrentChangeCount() => NativeMethods.GetClipboardSequenceNumber();

    public ClipboardSnapshot ReadSnapshot()
    {
        OpenWithRetry();
        try
        {
            if (_pngFormat != 0 && NativeMethods.IsClipboardFormatAvailable(_pngFormat))
            {
                var png = ReadGlobalBytes(NativeMethods.GetClipboardData(_pngFormat));
                if (png is { Length: > 0 }) return new ClipboardSnapshot(null, png);
            }

            if (NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfDib))
            {
                var dib = ReadGlobalBytes(NativeMethods.GetClipboardData(NativeMethods.CfDib));
                var png = dib is null ? null : DibCodec.DibToPng(dib);
                if (png is { Length: > 0 }) return new ClipboardSnapshot(null, png);
            }

            if (NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfUnicodeText))
            {
                var handle = NativeMethods.GetClipboardData(NativeMethods.CfUnicodeText);
                var pointer = handle == IntPtr.Zero ? IntPtr.Zero : NativeMethods.GlobalLock(handle);
                if (pointer != IntPtr.Zero)
                {
                    try
                    {
                        return new ClipboardSnapshot(Marshal.PtrToStringUni(pointer), null);
                    }
                    finally
                    {
                        _ = NativeMethods.GlobalUnlock(handle);
                    }
                }
            }

            return new ClipboardSnapshot(null, null);
        }
        finally
        {
            _ = NativeMethods.CloseClipboard();
        }
    }

    public void ClearContents()
    {
        OpenWithRetry();
        try
        {
            if (!NativeMethods.EmptyClipboard()) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            _ = NativeMethods.CloseClipboard();
        }
    }

    public void WriteText(string text)
    {
        var bytes = Encoding.Unicode.GetBytes(text + '\0');
        OpenWithRetry();
        try
        {
            SetGlobalBytes(NativeMethods.CfUnicodeText, bytes);
        }
        finally
        {
            _ = NativeMethods.CloseClipboard();
        }
    }

    public void WriteImageData(ReadOnlySpan<byte> data)
    {
        var png = DibCodec.ToPng(data)
            ?? throw new InvalidDataException("The image could not be converted to PNG.");
        var dib = DibCodec.ImageToDib(data)
            ?? throw new InvalidDataException("The image could not be converted to CF_DIB.");
        OpenWithRetry();
        try
        {
            if (_pngFormat != 0) SetGlobalBytes(_pngFormat, png);
            SetGlobalBytes(NativeMethods.CfDib, dib);
        }
        finally
        {
            _ = NativeMethods.CloseClipboard();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _ = NativeMethods.RemoveClipboardFormatListener(_messageWindow.Handle);
        _messageWindow.RemoveHook(WindowProcedure);
        _messageWindow.Dispose();
    }

    private IntPtr WindowProcedure(
        IntPtr window,
        int message,
        IntPtr wParam,
        IntPtr lParam,
        ref bool handled)
    {
        if (message == WmClipboardUpdate) Changed?.Invoke(this, EventArgs.Empty);
        return IntPtr.Zero;
    }

    private void OpenWithRetry()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (NativeMethods.OpenClipboard(_messageWindow.Handle)) return;
            Thread.Sleep(10 + (attempt * 5));
        }

        throw new Win32Exception(Marshal.GetLastWin32Error(), "The Windows clipboard is busy.");
    }

    private static byte[]? ReadGlobalBytes(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return null;
        var size = NativeMethods.GlobalSize(handle);
        if (size == 0 || size > int.MaxValue) return null;
        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            var bytes = new byte[(int)size];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            _ = NativeMethods.GlobalUnlock(handle);
        }
    }

    private static void SetGlobalBytes(uint format, ReadOnlySpan<byte> bytes)
    {
        var handle = NativeMethods.GlobalAlloc(NativeMethods.GmemMoveable, (nuint)bytes.Length);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var transferred = false;
        try
        {
            var pointer = NativeMethods.GlobalLock(handle);
            if (pointer == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                Marshal.Copy(bytes.ToArray(), 0, pointer, bytes.Length);
            }
            finally
            {
                _ = NativeMethods.GlobalUnlock(handle);
            }

            if (NativeMethods.SetClipboardData(format, handle) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            transferred = true;
        }
        finally
        {
            if (!transferred) _ = NativeMethods.GlobalFree(handle);
        }
    }
}
