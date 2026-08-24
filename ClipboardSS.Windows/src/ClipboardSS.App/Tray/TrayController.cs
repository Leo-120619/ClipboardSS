using System.Drawing;
using System.Windows;
using ClipboardSS.App.Settings;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Models;
using Forms = System.Windows.Forms;

namespace ClipboardSS.App.Tray;

public sealed class TrayController : IDisposable
{
    private readonly AppModel _model;
    private readonly SettingsStore _settings;
    private readonly Action _open;
    private readonly Action _devices;
    private readonly Action _preferences;
    private readonly Action _screenText;
    private readonly Action _quit;
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ContextMenuStrip _menu = new();

    public TrayController(
        AppModel model,
        SettingsStore settings,
        Action open,
        Action devices,
        Action preferences,
        Action screenText,
        Action quit)
    {
        _model = model;
        _settings = settings;
        _open = open;
        _devices = devices;
        _preferences = preferences;
        _screenText = screenText;
        _quit = quit;
        _menu.Opening += (_, _) => RebuildMenu();
        _icon = new Forms.NotifyIcon
        {
            Text = "ClipboardSS",
            Icon = LoadTrayIcon(),
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => _open();
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }

    private void RebuildMenu()
    {
        _menu.Items.Clear();
        Add("Open ClipboardSS", (_, _) => _open(), bold: true);
        Add("Select Screen Text", (_, _) => _screenText());
        _menu.Items.Add(new Forms.ToolStripSeparator());
        foreach (var clip in _model.Clips.Take(5))
        {
            var item = new Forms.ToolStripMenuItem(ClipTitle(clip)) { Tag = clip };
            item.Click += (_, _) => _model.Copy((ClipItem)item.Tag!);
            _menu.Items.Add(item);
        }
        if (_model.Clips.Count == 0)
            _menu.Items.Add(new Forms.ToolStripMenuItem("No recent clips") { Enabled = false });
        _menu.Items.Add(new Forms.ToolStripSeparator());
        Add("Devices…", (_, _) => _devices());
        Add("Preferences…", (_, _) => _preferences());
        var pause = Add("Pause sync", (_, _) => _model.IsSyncPaused = !_model.IsSyncPaused);
        pause.Checked = _model.IsSyncPaused;
        var startup = Add("Start at login", ToggleStartup);
        startup.Checked = _settings.Current.LaunchAtLogin;
        _menu.Items.Add(new Forms.ToolStripSeparator());
        Add("Quit ClipboardSS", (_, _) => _quit());
    }

    private Forms.ToolStripMenuItem Add(
        string text,
        EventHandler handler,
        bool bold = false)
    {
        var item = new Forms.ToolStripMenuItem(text);
        item.Click += handler;
        if (bold) item.Font = new Font(item.Font, System.Drawing.FontStyle.Bold);
        _menu.Items.Add(item);
        return item;
    }

    private async void ToggleStartup(object? sender, EventArgs args)
    {
        var enabled = !_settings.Current.LaunchAtLogin;
        try
        {
            var result = await StartupRegistration.SetEnabledAsync(enabled);
            _settings.Update(current => current with { LaunchAtLogin = result.IsEnabled });
            if (result.WasDeniedByUser)
            {
                _icon.ShowBalloonTip(
                    4000,
                    "ClipboardSS",
                    "Windows denied the request to start ClipboardSS at sign-in. Change it in Windows Startup Apps settings.",
                    Forms.ToolTipIcon.Warning);
            }
        }
        catch (Exception exception)
        {
            _icon.ShowBalloonTip(4000, "ClipboardSS", exception.Message, Forms.ToolTipIcon.Error);
        }
    }

    private static string ClipTitle(ClipItem clip)
    {
        var prefix = clip.Type == ClipType.Image ? "▣ " : "";
        var text = clip.PreviewText.ReplaceLineEndings(" ").Trim();
        if (text.Length > 48) text = $"{text[..47]}…";
        return prefix + text;
    }

    private static Icon LoadTrayIcon()
    {
        var executablePath = Environment.ProcessPath;
        return executablePath is null
            ? SystemIcons.Application
            : Icon.ExtractAssociatedIcon(executablePath) ?? SystemIcons.Application;
    }
}
