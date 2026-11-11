using System.Runtime.InteropServices;
using ClipboardSS.App.Win32;

namespace ClipboardSS.Core.Tests;

public sealed class PasteInjectorLayoutTests
{
    [Fact]
    public void InputStruct_HasNativeSize()
    {
        // SendInput rejects every call whose cbSize differs from sizeof(INPUT):
        // 40 bytes on 64-bit, 28 on 32-bit (the MOUSEINPUT member sets the union size).
        Assert.Equal(IntPtr.Size == 8 ? 40 : 28, Marshal.SizeOf<Input>());
    }
}
