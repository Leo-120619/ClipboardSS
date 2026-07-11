using System.Text.Json;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Storage;

public sealed class PairedDeviceStore
{
    private readonly object _gate = new();
    private readonly string _storagePath;
    private readonly IPairKeyStorage _keyStorage;
    private List<PairedDevice> _devices;

    public PairedDeviceStore(string storagePath, IPairKeyStorage keyStorage)
    {
        _storagePath = Path.GetFullPath(storagePath);
        _keyStorage = keyStorage;
        _devices = File.Exists(_storagePath)
            ? JsonSerializer.Deserialize<List<PairedDevice>>(File.ReadAllBytes(_storagePath), WireJson.Options)
                ?? []
            : [];
    }

    public IReadOnlyList<PairedDevice> Devices
    {
        get
        {
            lock (_gate)
            {
                return _devices.ToArray();
            }
        }
    }

    public void AddDevice(PairedDevice device, ReadOnlySpan<byte> key)
    {
        lock (_gate)
        {
            _keyStorage.StoreKey(key, device.Id);
            var index = _devices.FindIndex(item => item.Id == device.Id);
            if (index >= 0)
            {
                _devices[index] = device with { Connected = _devices[index].Connected };
            }
            else
            {
                _devices.Add(device);
            }

            Save();
        }
    }

    public void RemoveDevice(Guid id)
    {
        lock (_gate)
        {
            _keyStorage.DeleteKey(id);
            _devices.RemoveAll(device => device.Id == id);
            Save();
        }
    }

    public void SetConnected(Guid id, bool connected)
    {
        lock (_gate)
        {
            var index = _devices.FindIndex(device => device.Id == id);
            if (index < 0) return;
            _devices[index] = _devices[index] with { Connected = connected };
            Save();
        }
    }

    public bool IsConnected(Guid id)
    {
        lock (_gate)
        {
            return _devices.Find(device => device.Id == id)?.Connected == true;
        }
    }

    public byte[]? GetKey(Guid deviceId)
    {
        lock (_gate)
        {
            return _keyStorage.GetKey(deviceId);
        }
    }

    private void Save() =>
        AtomicFile.WriteAllBytes(
            _storagePath,
            JsonSerializer.SerializeToUtf8Bytes(_devices, WireJson.IndentedOptions));
}
