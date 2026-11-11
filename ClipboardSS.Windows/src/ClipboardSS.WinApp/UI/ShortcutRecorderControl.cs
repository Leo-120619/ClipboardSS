using System.Media;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using ClipboardSS.App.Settings;

namespace ClipboardSS.App.UI;

public sealed class ShortcutRecordedEventArgs(ShortcutSettings shortcut) : EventArgs
{
    public ShortcutSettings Shortcut { get; } = shortcut;
}

public sealed class ShortcutRecorderControl : Button
{
    public static readonly DependencyProperty ShortcutProperty = DependencyProperty.Register(
        nameof(Shortcut),
        typeof(ShortcutSettings),
        typeof(ShortcutRecorderControl),
        new PropertyMetadata(null, OnShortcutChanged));

    private bool _isRecording;

    public ShortcutRecorderControl()
    {
        MinHeight = 44;
        MinWidth = 220;
        Padding = new Thickness(12, 0, 12, 0);
        HorizontalContentAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetHelpText(this, "Activate, then press a shortcut containing at least one modifier key.");
        UpdateContent();
    }

    public ShortcutSettings? Shortcut
    {
        get => (ShortcutSettings?)GetValue(ShortcutProperty);
        set => SetValue(ShortcutProperty, value);
    }

    public event EventHandler<ShortcutRecordedEventArgs>? ShortcutRecorded;
    public event Action<string?>? RecordingMessageChanged;
    public event Action<bool>? RecordingStateChanged;

    protected override void OnClick()
    {
        BeginRecording();
        base.OnClick();
    }

    protected override void OnPreviewKeyDown(KeyEventArgs args)
    {
        if (!_isRecording)
        {
            base.OnPreviewKeyDown(args);
            return;
        }

        args.Handled = true;
        var key = args.Key == Key.System ? args.SystemKey : args.Key;
        if (key == Key.Escape)
        {
            EndRecording();
            return;
        }

        var virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
        var modifiers = CurrentModifiers();
        var candidate = new ShortcutSettings((uint)modifiers, virtualKey);
        if (!candidate.IsValid)
        {
            SystemSounds.Beep.Play();
            Content = "Add Ctrl, Alt, Shift, or Windows";
            RecordingMessageChanged?.Invoke("A shortcut needs a modifier plus a non-modifier key.");
            return;
        }

        Shortcut = candidate;
        EndRecording();
        ShortcutRecorded?.Invoke(this, new ShortcutRecordedEventArgs(candidate));
    }

    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs args)
    {
        if (_isRecording) EndRecording();
        base.OnLostKeyboardFocus(args);
    }

    private static void OnShortcutChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((ShortcutRecorderControl)sender).UpdateContent();

    private void BeginRecording()
    {
        _isRecording = true;
        RecordingStateChanged?.Invoke(true);
        Focus();
        Content = "Press shortcut…  (Esc to cancel)";
        AutomationProperties.SetName(this, "Recording shortcut");
        RecordingMessageChanged?.Invoke(null);
    }

    private void EndRecording()
    {
        _isRecording = false;
        RecordingStateChanged?.Invoke(false);
        UpdateContent();
        RecordingMessageChanged?.Invoke(null);
    }

    private void UpdateContent()
    {
        if (_isRecording) return;
        Content = Shortcut?.DisplayName ?? "None";
        AutomationProperties.SetName(this, $"Shortcut: {Content}. Activate to record a new shortcut.");
    }

    private static ShortcutModifiers CurrentModifiers()
    {
        var result = ShortcutModifiers.None;
        var modifiers = Keyboard.Modifiers;
        if (modifiers.HasFlag(ModifierKeys.Control)) result |= ShortcutModifiers.Control;
        if (modifiers.HasFlag(ModifierKeys.Alt)) result |= ShortcutModifiers.Alt;
        if (modifiers.HasFlag(ModifierKeys.Shift)) result |= ShortcutModifiers.Shift;
        if (modifiers.HasFlag(ModifierKeys.Windows)) result |= ShortcutModifiers.Windows;
        return result;
    }
}
