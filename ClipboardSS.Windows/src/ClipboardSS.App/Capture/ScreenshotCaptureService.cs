using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ClipboardSS.App.Win32;

namespace ClipboardSS.App.Capture;

public sealed class ScreenshotCaptureService
{
    public async Task<byte[]> CaptureRegionAsync(CancellationToken cancellationToken = default)
    {
        var region = await RegionSelectWindow.SelectRegionAsync(cancellationToken);
        return CapturePng(region);
    }

    public byte[] CapturePng(PhysicalRect region)
    {
        if (!region.IsUsable)
            throw new ArgumentOutOfRangeException(nameof(region), "Choose a region larger than one pixel.");

        var screenDc = NativeMethods.GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero) throw new Win32Exception("Unable to access the screen for capture.");

        IntPtr memoryDc = IntPtr.Zero;
        IntPtr bitmapHandle = IntPtr.Zero;
        IntPtr previousObject = IntPtr.Zero;
        try
        {
            memoryDc = NativeMethods.CreateCompatibleDC(screenDc);
            if (memoryDc == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            bitmapHandle = NativeMethods.CreateCompatibleBitmap(screenDc, region.Width, region.Height);
            if (bitmapHandle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            previousObject = NativeMethods.SelectObject(memoryDc, bitmapHandle);
            if (previousObject == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!NativeMethods.BitBlt(
                    memoryDc,
                    0,
                    0,
                    region.Width,
                    region.Height,
                    screenDc,
                    region.X,
                    region.Y,
                    NativeMethods.Srccopy | NativeMethods.CaptureBlt))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not capture that screen region.");

            using var bitmap = Image.FromHbitmap(bitmapHandle);
            using var stream = new MemoryStream();
            bitmap.Save(stream, ImageFormat.Png);
            return stream.ToArray();
        }
        finally
        {
            if (previousObject != IntPtr.Zero && memoryDc != IntPtr.Zero)
                _ = NativeMethods.SelectObject(memoryDc, previousObject);
            if (bitmapHandle != IntPtr.Zero) _ = NativeMethods.DeleteObject(bitmapHandle);
            if (memoryDc != IntPtr.Zero) _ = NativeMethods.DeleteDC(memoryDc);
            _ = NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
