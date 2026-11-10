using ClipboardSS.App.Settings;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Tests;

public sealed class CorruptStateFileTests
{
    private const string Truncated = "{\"trunc";
    private static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_000);

    [Fact]
    public void CorruptClipsFileIsQuarantinedAndStoreStartsEmpty()
    {
        using var directory = new TemporaryDirectory();
        var clipsPath = Path.Combine(directory.Path, "clips.json");
        File.WriteAllText(clipsPath, Truncated);

        var store = new ClipStore(directory.Path, () => At);

        var quarantined = Path.Combine(directory.Path, "clips.json.corrupt-19700101-001640");
        Assert.Empty(store.Items);
        Assert.Equal(quarantined, store.QuarantinedFilePath);
        Assert.Equal(Truncated, File.ReadAllText(quarantined));
        Assert.False(File.Exists(clipsPath));
    }

    [Fact]
    public void CorruptPairedDevicesFileIsQuarantinedAndStoreStartsEmpty()
    {
        using var directory = new TemporaryDirectory();
        var devicesPath = Path.Combine(directory.Path, "paired-devices.json");
        File.WriteAllText(devicesPath, Truncated);

        var store = new PairedDeviceStore(devicesPath, new InMemoryPairKeyStorage(), () => At);

        var quarantined = Path.Combine(directory.Path, "paired-devices.json.corrupt-19700101-001640");
        Assert.Empty(store.Devices);
        Assert.Equal(quarantined, store.QuarantinedFilePath);
        Assert.True(File.Exists(quarantined));
        Assert.False(File.Exists(devicesPath));
    }

    [Fact]
    public void CorruptSettingsFileIsQuarantinedAndStoreStartsWithDefaults()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        File.WriteAllText(settingsPath, Truncated);

        var store = new SettingsStore(directory.Path, () => At);

        var quarantined = Path.Combine(directory.Path, "settings.json.corrupt-19700101-001640");
        Assert.Equal(new AppSettings().ClipboardShortcut, store.Current.ClipboardShortcut);
        Assert.Equal(quarantined, store.QuarantinedFilePath);
        Assert.Equal(Truncated, File.ReadAllText(quarantined));
        Assert.Equal(store.Current.DeviceId, new SettingsStore(directory.Path).Current.DeviceId);
    }

    [Fact]
    public void QuarantineNeverOverwritesAnEarlierCopy()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "clips.json");

        File.WriteAllText(path, "first");
        var first = CorruptStateFile.Quarantine(path, At);
        File.WriteAllText(path, "second");
        var second = CorruptStateFile.Quarantine(path, At);

        Assert.NotEqual(first, second);
        Assert.Equal("first", File.ReadAllText(first));
        Assert.Equal("second", File.ReadAllText(second));
    }

    [Fact]
    public void HealthyClipsFileIsNotQuarantined()
    {
        using var directory = new TemporaryDirectory();
        new ClipStore(directory.Path).AddText("kept");

        var reloaded = new ClipStore(directory.Path);

        Assert.Equal(["kept"], reloaded.Items.Select(item => item.Text));
        Assert.Null(reloaded.QuarantinedFilePath);
    }

    private sealed class InMemoryPairKeyStorage : IPairKeyStorage
    {
        private readonly Dictionary<Guid, byte[]> _keys = [];
        public void StoreKey(ReadOnlySpan<byte> key, Guid deviceId) => _keys[deviceId] = key.ToArray();
        public byte[]? GetKey(Guid deviceId) => _keys.GetValueOrDefault(deviceId)?.ToArray();
        public void DeleteKey(Guid deviceId) => _keys.Remove(deviceId);
    }
}
