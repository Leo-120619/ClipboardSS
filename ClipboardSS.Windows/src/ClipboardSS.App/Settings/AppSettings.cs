using System.Text.Json.Serialization;

namespace ClipboardSS.App.Settings;

public sealed record WindowFrame(double Left, double Top, double Width, double Height);

[Flags]
public enum ShortcutModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Windows = 0x0008,
}

public sealed record ShortcutSettings(uint Modifiers, uint VirtualKey)
{
    private const uint ModifierMask = 0x000f;

    [JsonIgnore]
    public ShortcutModifiers ModifierKeys => (ShortcutModifiers)(Modifiers & ModifierMask);

    [JsonIgnore]
    public bool IsValid => ModifierKeys != ShortcutModifiers.None && VirtualKey != 0 && !IsModifierKey(VirtualKey);

    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            var names = new List<string>();
            if (ModifierKeys.HasFlag(ShortcutModifiers.Control)) names.Add("Ctrl");
            if (ModifierKeys.HasFlag(ShortcutModifiers.Alt)) names.Add("Alt");
            if (ModifierKeys.HasFlag(ShortcutModifiers.Shift)) names.Add("Shift");
            if (ModifierKeys.HasFlag(ShortcutModifiers.Windows)) names.Add("Windows");
            names.Add(KeyName(VirtualKey));
            return string.Join(" + ", names);
        }
    }

    public override string ToString() => DisplayName;

    public static bool IsModifierKey(uint virtualKey) => virtualKey is
        0x10 or 0x11 or 0x12 or 0x5b or 0x5c or 0xa0 or 0xa1 or 0xa2 or 0xa3 or 0xa4 or 0xa5;

    private static string KeyName(uint virtualKey)
    {
        if (virtualKey is >= 0x41 and <= 0x5a) return ((char)virtualKey).ToString();
        if (virtualKey is >= 0x30 and <= 0x39) return ((char)virtualKey).ToString();
        if (virtualKey is >= 0x70 and <= 0x87) return $"F{virtualKey - 0x6f}";
        return virtualKey switch
        {
            0x08 => "Backspace",
            0x09 => "Tab",
            0x0d => "Enter",
            0x1b => "Escape",
            0x20 => "Space",
            0x21 => "Page Up",
            0x22 => "Page Down",
            0x23 => "End",
            0x24 => "Home",
            0x25 => "Left",
            0x26 => "Up",
            0x27 => "Right",
            0x28 => "Down",
            0x2d => "Insert",
            0x2e => "Delete",
            0xba => ";",
            0xbb => "+",
            0xbc => ",",
            0xbd => "-",
            0xbe => ".",
            0xbf => "/",
            0xc0 => "`",
            0xdb => "[",
            0xdc => "\\",
            0xdd => "]",
            0xde => "'",
            _ => $"Key 0x{virtualKey:X2}",
        };
    }
}

public sealed record AppSettings
{
    public Guid DeviceId { get; init; } = Guid.NewGuid();
    public string DeviceName { get; init; } = Environment.MachineName;
    public bool LaunchAtLogin { get; init; } = true;
    public ShortcutSettings ClipboardShortcut { get; init; } = new(
        (uint)(ShortcutModifiers.Control | ShortcutModifiers.Alt),
        0x56);
    public ShortcutSettings? ScreenshotShortcut { get; init; }
    public ShortcutSettings? ScreenTextShortcut { get; init; }
    public WindowFrame? MainWindowFrame { get; init; }
}

public static class ShortcutValidation
{
    public static string? FindDuplicate(AppSettings settings)
    {
        if (settings.ScreenshotShortcut is not null && settings.ScreenshotShortcut == settings.ClipboardShortcut)
            return "Open ClipboardSS and Screenshot";
        if (settings.ScreenTextShortcut is not null && settings.ScreenTextShortcut == settings.ClipboardShortcut)
            return "Open ClipboardSS and Screen Text OCR";
        if (settings.ScreenshotShortcut is not null && settings.ScreenshotShortcut == settings.ScreenTextShortcut)
            return "Screenshot and Screen Text OCR";
        return null;
    }
}
