using ClipboardSS.Core.Models;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.Core.Tests;

public sealed class ClipStoreTests
{
    [Fact]
    public void StoresNewestFirstAndReloadsFromDisk()
    {
        using var directory = new TemporaryDirectory();
        var clock = new TestClock(DateTimeOffset.FromUnixTimeSeconds(1_000));
        var store = new ClipStore(directory.Path, clock.Now);

        var first = store.AddText("first");
        clock.Advance(TimeSpan.FromSeconds(10));
        var second = store.AddText("second");

        Assert.Equal([second.Id, first.Id], store.Items.Select(item => item.Id));
        var reloaded = new ClipStore(directory.Path, clock.Now);
        Assert.Equal(["second", "first"], reloaded.Items.Select(item => item.Text));
    }

    [Fact]
    public void DeduplicatesByHashRefreshesTimestampAndPreservesIdentityAndPin()
    {
        using var directory = new TemporaryDirectory();
        var clock = new TestClock(DateTimeOffset.FromUnixTimeSeconds(2_000));
        var store = new ClipStore(directory.Path, clock.Now);
        var original = store.AddText("repeat");
        store.SetPinned(original.Id, true);
        clock.Advance(TimeSpan.FromSeconds(20));

        var duplicate = store.AddText("repeat");

        Assert.Equal(original.Id, duplicate.Id);
        Assert.Single(store.Items);
        Assert.True(store.Items[0].IsPinned);
        Assert.Equal(clock.Now(), store.Items[0].CreatedAt);
    }

    [Fact]
    public void MarkCopiedSetsTimestampAndMovesClipToFront()
    {
        using var directory = new TemporaryDirectory();
        var clock = new TestClock(DateTimeOffset.FromUnixTimeSeconds(3_000));
        var store = new ClipStore(directory.Path, clock.Now);
        var first = store.AddText("first");
        var second = store.AddText("second");
        clock.Advance(TimeSpan.FromMinutes(1));

        store.MarkCopied(first.Id);

        Assert.Equal([first.Id, second.Id], store.Items.Select(item => item.Id));
        Assert.Equal(clock.Now(), store.Items[0].LastCopiedAt);
    }

    [Fact]
    public void RemovesOnlyUnpinnedClipsOlderThanSevenDays()
    {
        using var directory = new TemporaryDirectory();
        var clock = new TestClock(DateTimeOffset.FromUnixTimeSeconds(4_000));
        var store = new ClipStore(directory.Path, clock.Now);
        var expired = store.AddText("expired");
        var pinned = store.AddText("pinned");
        store.SetPinned(pinned.Id, true);
        clock.Advance(TimeSpan.FromDays(8) + TimeSpan.FromSeconds(1));
        var fresh = store.AddText("fresh");

        store.CleanupExpiredClips();

        Assert.DoesNotContain(store.Items, item => item.Id == expired.Id);
        Assert.Contains(store.Items, item => item.Id == pinned.Id);
        Assert.Contains(store.Items, item => item.Id == fresh.Id);
    }

    [Fact]
    public void StoresImagesAsFilesDeduplicatesAndDeletesBackingFile()
    {
        using var directory = new TemporaryDirectory();
        var clock = new TestClock(DateTimeOffset.FromUnixTimeSeconds(5_000));
        var store = new ClipStore(directory.Path, clock.Now);
        byte[] imageData = [0x89, 0x50, 0x4e, 0x47];
        var clip = store.AddImageData(imageData, "png", "Screenshot");
        var imagePath = clip.ResolveImagePath(directory.Path);

        Assert.Equal(imageData, File.ReadAllBytes(imagePath));
        Assert.Equal(clip.Id, store.AddImageData(imageData, "jpg").Id);
        Assert.Single(Directory.GetFiles(System.IO.Path.Combine(directory.Path, "Images")));

        store.Delete(clip.Id);
        Assert.False(File.Exists(imagePath));
    }

    [Fact]
    public void PreviewSearchAndFiltersMatchSwiftBehavior()
    {
        using var directory = new TemporaryDirectory();
        var store = new ClipStore(directory.Path);
        var empty = store.AddText(" \n\t ");
        var searchable = store.AddText("First line\nSecret second line");
        var image = store.AddImageData([1, 2, 3], "png", "Receipt image");
        store.SetPinned(image.Id, true);

        Assert.Equal("Empty text", empty.PreviewText);
        Assert.Equal("First line Secret second line", searchable.PreviewText);
        Assert.Equal([searchable.Id], store.Clips("second", ClipFilter.Text).Select(item => item.Id));
        Assert.Equal([image.Id], store.Clips("receipt", ClipFilter.Image).Select(item => item.Id));
        Assert.Equal([image.Id], store.Clips(string.Empty, ClipFilter.Pinned).Select(item => item.Id));
    }

    private sealed class TestClock(DateTimeOffset current)
    {
        private DateTimeOffset _current = current;
        public DateTimeOffset Now() => _current;
        public void Advance(TimeSpan interval) => _current += interval;
    }
}
