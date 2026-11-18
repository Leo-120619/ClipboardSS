using System.IO.Compression;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.Core.Tests;

public sealed class FolderArchiverTests
{
    [Fact]
    public void ZipsFolderWithItselfAtTheRootAndKeepsNamesUnique()
    {
        using var directory = new TemporaryDirectory();
        var folder = Path.Combine(directory.Path, "Schema Therapy 2");
        Directory.CreateDirectory(Path.Combine(folder, "sub"));
        File.WriteAllText(Path.Combine(folder, "sub", "inner.txt"), "inner");
        var output = Path.Combine(directory.Path, "out");

        var first = FolderArchiver.Zip(folder, output);
        var second = FolderArchiver.Zip(folder + Path.DirectorySeparatorChar, output);

        Assert.Equal("Schema Therapy 2.zip", Path.GetFileName(first));
        Assert.Equal("Schema Therapy 2-2.zip", Path.GetFileName(second));
        using var archive = ZipFile.OpenRead(first);
        var entry = Assert.Single(archive.Entries, item => item.Name == "inner.txt");
        Assert.Equal("Schema Therapy 2/sub/inner.txt", entry.FullName.Replace('\\', '/'));
        Assert.True(Directory.Exists(folder));
    }

    [Fact]
    public void MissingFolderThrows()
    {
        using var directory = new TemporaryDirectory();
        Assert.Throws<DirectoryNotFoundException>(() =>
            FolderArchiver.Zip(Path.Combine(directory.Path, "nope"), directory.Path));
    }
}
