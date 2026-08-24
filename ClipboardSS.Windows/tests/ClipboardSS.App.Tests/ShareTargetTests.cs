using System.Xml.Linq;
using ClipboardSS.App;
using ClipboardSS.Core.Models;

namespace ClipboardSS.App.Tests;

public sealed class ShareTargetTests
{
    [Fact]
    public void PackageManifestRegistersStorageItemsForAnyFileType()
    {
        var root = FindRepositoryRoot();
        var manifest = XDocument.Load(Path.Combine(root, "ClipboardSS.Windows", "Packaging", "AppxManifest.xml"));
        XNamespace uap = "http://schemas.microsoft.com/appx/manifest/uap/windows10";

        var shareTarget = manifest.Descendants(uap + "ShareTarget").Single();
        Assert.NotNull(shareTarget.Descendants(uap + "SupportsAnyFileType").SingleOrDefault());
        Assert.Contains(shareTarget.Elements(uap + "DataFormat"), item => item.Value == "StorageItems");
    }

    [Fact]
    public void StagedFileCleanupDeletesFilesAndIgnoresMissingPaths()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ClipboardSS-share-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var first = Path.Combine(directory, "first.pdf");
        var second = Path.Combine(directory, "second.pdf");
        File.WriteAllText(first, "first");
        File.WriteAllText(second, "second");

        try
        {
            ShareFileStaging.DeleteFiles([first, second, Path.Combine(directory, "missing.pdf")]);
            Assert.False(File.Exists(first));
            Assert.False(File.Exists(second));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void ComposeSendTargetsExcludesPausedDevicesIncludingMdnsPeers()
    {
        var connected = Guid.NewGuid();
        var paused = Guid.NewGuid();
        var targets = AppModel.ComposeSendTargets(
            [new Peer(connected, "Phone", "10.0.0.2", 51888), new Peer(paused, "Tablet", "10.0.0.3", 51888)],
            [new PairedDevice(connected, "Phone"), new PairedDevice(paused, "Tablet", Connected: false)]);

        Assert.Single(targets);
        Assert.Equal(connected, targets[0].Id);
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "ClipboardSS.Windows", "ClipboardSS.Windows.sln")))
                return directory.FullName;
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate the ClipboardSS repository root.");
    }
}
