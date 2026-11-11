using System.Diagnostics;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace ClipboardSS.App.Notifications;

public interface IReceivedFileNotificationService : IDisposable
{
    void Initialize();
    void ShowReceivedFile(string savedPath);
}

public sealed class ReceivedFileNotificationService : IReceivedFileNotificationService
{
    private bool _registered;

    public void Initialize()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += NotificationInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch { }
    }

    public void ShowReceivedFile(string savedPath)
    {
        if (!_registered || string.IsNullOrWhiteSpace(savedPath)) return;
        try
        {
            var notification = new AppNotificationBuilder()
                .AddText("File received")
                .AddText(Path.GetFileName(savedPath))
                .AddArgument("path", savedPath)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch { }
    }

    private static void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        try
        {
            if (!args.Arguments.TryGetValue("path", out var path) || !File.Exists(path)) return;
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch { }
    }

    public void Dispose()
    {
        if (!_registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
            AppNotificationManager.Default.Unregister();
        }
        catch { }
        _registered = false;
    }
}
