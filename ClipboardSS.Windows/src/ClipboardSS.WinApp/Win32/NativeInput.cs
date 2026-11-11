using System.Runtime.InteropServices;

namespace ClipboardSS.App.Win32;

// Win32 INPUT for SendInput. Kept free of Windows-only dependencies so the layout test
// (ClipboardSS.Core.Tests/PasteInjectorLayoutTests.cs) can link this file and run anywhere.

[StructLayout(LayoutKind.Sequential)]
internal struct Input
{
    public uint Type;
    public InputUnion Data;
}

[StructLayout(LayoutKind.Explicit)]
internal struct InputUnion
{
    // All three members must be declared: MOUSEINPUT is the largest and sets sizeof(INPUT).
    [FieldOffset(0)] public MouseInputData Mouse;
    [FieldOffset(0)] public KeyboardInputData Keyboard;
    [FieldOffset(0)] public HardwareInputData Hardware;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MouseInputData
{
    public int dx;
    public int dy;
    public uint mouseData;
    public uint dwFlags;
    public uint time;
    public IntPtr dwExtraInfo;
}

[StructLayout(LayoutKind.Sequential)]
internal struct KeyboardInputData
{
    public ushort VirtualKey;
    public ushort ScanCode;
    public uint Flags;
    public uint Time;
    public IntPtr ExtraInfo;
}

[StructLayout(LayoutKind.Sequential)]
internal struct HardwareInputData
{
    public uint Message;
    public ushort ParamL;
    public ushort ParamH;
}
