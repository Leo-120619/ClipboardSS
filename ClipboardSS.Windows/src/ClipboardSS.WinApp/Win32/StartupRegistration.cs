using Microsoft.Win32;
using Windows.ApplicationModel;

namespace ClipboardSS.App.Win32;

public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "ClipboardSS";

    public static async Task<bool> IsEnabledAsync()
    {
        if (IsPackaged())
        {
            var startupTask = await StartupTask.GetAsync("ClipboardSSStartup");
            return startupTask.State == StartupTaskState.Enabled;
        }

        using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
        return key?.GetValue(ValueName) is string;
    }

    public static async Task<StartupRegistrationResult> SetEnabledAsync(bool enabled)
    {
        if (IsPackaged())
        {
            var startupTask = await StartupTask.GetAsync("ClipboardSSStartup");
            if (enabled)
            {
                if (startupTask.State == StartupTaskState.Enabled)
                    return new StartupRegistrationResult(true, false);

                var state = await startupTask.RequestEnableAsync();
                return new StartupRegistrationResult(state == StartupTaskState.Enabled, state == StartupTaskState.DisabledByUser);
            }

            startupTask.Disable();
            var isEnabled = (await StartupTask.GetAsync("ClipboardSSStartup")).State == StartupTaskState.Enabled;
            return new StartupRegistrationResult(isEnabled, false);
        }

        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (!enabled)
        {
            key.DeleteValue(ValueName, false);
            return new StartupRegistrationResult(false, false);
        }

        var executablePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("The application executable path is unavailable.");
        key.SetValue(ValueName, $"\"{executablePath}\"", RegistryValueKind.String);
        return new StartupRegistrationResult(true, false);
    }

    private static bool IsPackaged()
    {
        try
        {
            return Package.Current is not null;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }
}

public sealed record StartupRegistrationResult(bool IsEnabled, bool WasDeniedByUser);
