using System.IO.Compression;

namespace ClipboardSS.Core.Sync;

/// <summary>
/// Turns a folder into a single <c>.zip</c> so it can travel through the one-file transfer
/// protocol, matching the Mac app: the archive holds the folder itself at its root.
/// </summary>
public static class FolderArchiver
{
    /// <summary>Zips <paramref name="directory"/> into <paramref name="destinationDirectory"/> as
    /// <c>&lt;folder name&gt;.zip</c> (made unique if taken) and returns the archive path.</summary>
    public static string Zip(string directory, string destinationDirectory)
    {
        var source = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException($"Folder not found: {directory}");
        Directory.CreateDirectory(destinationDirectory);

        var name = Path.GetFileName(source);
        if (string.IsNullOrWhiteSpace(name)) name = "Folder";
        var destination = Path.Combine(destinationDirectory, $"{name}.zip");
        for (var counter = 2; File.Exists(destination); counter++)
            destination = Path.Combine(destinationDirectory, $"{name}-{counter}.zip");

        ZipFile.CreateFromDirectory(source, destination, CompressionLevel.Optimal, includeBaseDirectory: true);
        return destination;
    }
}
