namespace ClipboardSS.Core.Storage;

public interface IPairKeyStorage
{
    void StoreKey(ReadOnlySpan<byte> key, Guid deviceId);
    byte[]? GetKey(Guid deviceId);
    void DeleteKey(Guid deviceId);
}
