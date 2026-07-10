using System.Text.Json;
using ClipboardSS.App.Settings;

namespace ClipboardSS.Core.Tests;

public sealed class ShortcutSettingsTests
{
    [Fact]
    public void DefaultClipboardShortcutIsControlAltV()
    {
        var settings = new AppSettings();

        Assert.True(settings.ClipboardShortcut.IsValid);
        Assert.Equal("Ctrl + Alt + V", settings.ClipboardShortcut.DisplayName);
    }

    [Theory]
    [InlineData(0, 0x56)]
    [InlineData((uint)ShortcutModifiers.Control, 0x11)]
    [InlineData((uint)ShortcutModifiers.Alt, 0)]
    public void RejectsMissingModifierModifierOnlyAndMissingKey(uint modifiers, uint key)
    {
        Assert.False(new ShortcutSettings(modifiers, key).IsValid);
    }

    [Fact]
    public void DisplaysFunctionAndNavigationKeys()
    {
        Assert.Equal(
            "Ctrl + Shift + F12",
            new ShortcutSettings(
                (uint)(ShortcutModifiers.Control | ShortcutModifiers.Shift),
                0x7b).DisplayName);
        Assert.Equal(
            "Windows + Page Down",
            new ShortcutSettings((uint)ShortcutModifiers.Windows, 0x22).DisplayName);
    }

    [Fact]
    public void FindsConflictsAcrossAllThreeActions()
    {
        var shortcut = new ShortcutSettings((uint)ShortcutModifiers.Control, 0x41);

        Assert.Equal(
            "Open ClipboardSS and Screenshot",
            ShortcutValidation.FindDuplicate(new AppSettings { ClipboardShortcut = shortcut, ScreenshotShortcut = shortcut }));
        Assert.Equal(
            "Open ClipboardSS and Screen Text OCR",
            ShortcutValidation.FindDuplicate(new AppSettings { ClipboardShortcut = shortcut, ScreenTextShortcut = shortcut }));
        Assert.Equal(
            "Screenshot and Screen Text OCR",
            ShortcutValidation.FindDuplicate(new AppSettings
            {
                ScreenshotShortcut = shortcut,
                ScreenTextShortcut = shortcut,
            }));
    }

    [Fact]
    public void SettingsStorePersistsShortcutChanges()
    {
        using var directory = new TemporaryDirectory();
        var shortcut = new ShortcutSettings(
            (uint)(ShortcutModifiers.Control | ShortcutModifiers.Shift),
            0x42);
        var store = new SettingsStore(directory.Path);

        store.Update(current => current with { ClipboardShortcut = shortcut });

        Assert.Equal(shortcut, store.Current.ClipboardShortcut);
        Assert.Equal(shortcut, new SettingsStore(directory.Path).Current.ClipboardShortcut);

        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory.Path, "settings.json")));
        var savedShortcut = document.RootElement.GetProperty("clipboardShortcut");
        Assert.Equal(
            new[] { "modifiers", "virtualKey" },
            savedShortcut.EnumerateObject().Select(property => property.Name).ToArray());
    }
}
