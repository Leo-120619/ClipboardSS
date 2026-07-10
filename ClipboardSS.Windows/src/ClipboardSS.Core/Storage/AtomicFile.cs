namespace ClipboardSS.Core.Storage;

internal static class AtomicFile
{
    public static void WriteAllBytes(string path, ReadOnlySpan<byte> data)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new ArgumentException("The file path must have a parent directory.", nameof(path));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");

        try
        {
            File.WriteAllBytes(temporaryPath, data.ToArray());
            if (File.Exists(path))
            {
                try
                {
                    File.Replace(temporaryPath, path, null);
                }
                catch (PlatformNotSupportedException)
                {
                    File.Move(temporaryPath, path, true);
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
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
