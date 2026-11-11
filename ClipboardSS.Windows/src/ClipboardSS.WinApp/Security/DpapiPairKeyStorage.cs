using System.Security.Cryptography;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.App.Security;

public sealed class DpapiPairKeyStorage : IPairKeyStorage
{
    private readonly string _keyDirectory;

    public DpapiPairKeyStorage(string storageDirectory)
    {
        _keyDirectory = Path.Combine(storageDirectory, "keys");
        Directory.CreateDirectory(_keyDirectory);
    }

    public void StoreKey(ReadOnlySpan<byte> key, Guid deviceId)
    {
        var protectedBytes = ProtectedData.Protect(key.ToArray(), null, DataProtectionScope.CurrentUser);
        var path = PathFor(deviceId);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temporaryPath, protectedBytes);
            if (File.Exists(path))
            {
                try
                {
                    File.Replace(temporaryPath, path, null);
                }
                catch (IOException)
                {
                    File.Move(temporaryPath, path, true);
                }
            }
            else
            {
                File.Move(temporaryPath, path);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    public byte[]? GetKey(Guid deviceId)
    {
        var path = PathFor(deviceId);
        return File.Exists(path)
            ? ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser)
            : null;
    }

    public void DeleteKey(Guid deviceId)
    {
        var path = PathFor(deviceId);
        if (File.Exists(path)) File.Delete(path);
    }

    private string PathFor(Guid deviceId) =>
        Path.Combine(_keyDirectory, $"{deviceId:D}.bin".ToLowerInvariant());
}
