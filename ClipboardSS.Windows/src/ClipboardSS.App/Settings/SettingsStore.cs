using System.Text.Json;
using ClipboardSS.Core.Json;

namespace ClipboardSS.App.Settings;

public sealed class SettingsStore
{
    private readonly object _gate = new();
    private readonly string _path;

    public SettingsStore(string storageDirectory)
    {
        StorageDirectory = Path.GetFullPath(storageDirectory);
        Directory.CreateDirectory(StorageDirectory);
        _path = Path.Combine(StorageDirectory, "settings.json");
        Current = Load();
    }

    public string StorageDirectory { get; }
    public AppSettings Current { get; private set; }

    public static string ResolveStorageDirectory()
    {
        var overridePath = Environment.GetEnvironmentVariable("CLIPBOARDSS_STORAGE_DIR");
        return !string.IsNullOrWhiteSpace(overridePath)
            ? overridePath
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "ClipboardSS");
    }

    public void Update(Func<AppSettings, AppSettings> update)
    {
        lock (_gate)
        {
            var next = update(Current);
            Write(next);
            Current = next;
        }
    }

    private AppSettings Load()
    {
        if (!File.Exists(_path))
        {
            var settings = new AppSettings();
            Write(settings);
            return settings;
        }

        return JsonSerializer.Deserialize<AppSettings>(File.ReadAllBytes(_path), WireJson.Options)
            ?? throw new InvalidDataException("settings.json is empty or invalid.");
    }

    private void Write(AppSettings settings)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(settings, WireJson.IndentedOptions);
        var temporaryPath = Path.Combine(StorageDirectory, $".settings.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporaryPath, bytes);
            if (File.Exists(_path))
            {
                try
                {
                    File.Replace(temporaryPath, _path, null);
                }
                catch (IOException)
                {
                    File.Move(temporaryPath, _path, true);
                }
            }
            else
            {
                File.Move(temporaryPath, _path);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }
}
