using System.Text.Json;
using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Json;
using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Storage;

public sealed class ClipStore
{
    public static readonly TimeSpan DefaultExpiration = TimeSpan.FromDays(7);

    private readonly object _gate = new();
    private readonly Func<DateTimeOffset> _now;
    private readonly TimeSpan _expiration;
    private readonly string _metadataPath;
    private readonly string _imageDirectory;
    private List<ClipItem> _items;

    public ClipStore(
        string storageDirectory,
        Func<DateTimeOffset>? now = null,
        TimeSpan? expiration = null)
    {
        StorageDirectory = Path.GetFullPath(storageDirectory);
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _expiration = expiration ?? DefaultExpiration;
        _metadataPath = Path.Combine(StorageDirectory, "clips.json");
        _imageDirectory = Path.Combine(StorageDirectory, "Images");
        Directory.CreateDirectory(StorageDirectory);
        Directory.CreateDirectory(_imageDirectory);
        _items = File.Exists(_metadataPath)
            ? JsonSerializer.Deserialize<List<ClipItem>>(File.ReadAllBytes(_metadataPath), WireJson.Options)
                ?? []
            : [];
    }

    public string StorageDirectory { get; }

    public IReadOnlyList<ClipItem> Items
    {
        get
        {
            lock (_gate)
            {
                return _items.ToArray();
            }
        }
    }

    public ClipItem AddText(string text)
    {
        var trimmedPreview = text.Replace("\n", " ", StringComparison.Ordinal).Trim();
        var clip = new ClipItem
        {
            Type = ClipType.Text,
            CreatedAt = _now(),
            Text = text,
            PreviewText = trimmedPreview.Length == 0 ? "Empty text" : trimmedPreview,
            ContentHash = ContentHasher.TextHash(text),
        };

        lock (_gate)
        {
            return Upsert(clip);
        }
    }

    public ClipItem AddImageData(
        ReadOnlySpan<byte> data,
        string fileExtension,
        string previewText = "Image")
    {
        var hash = ContentHasher.ImageHash(data);
        lock (_gate)
        {
            var existing = _items.FirstOrDefault(item => item.ContentHash == hash);
            if (existing is not null)
            {
                return RefreshExisting(existing);
            }

            var extension = fileExtension.Trim();
            if (extension.Length == 0)
            {
                extension = "png";
            }

            var fileName = $"{Guid.NewGuid():D}.{extension}";
            var relativePath = Path.Combine("Images", fileName);
            AtomicFile.WriteAllBytes(Path.Combine(StorageDirectory, relativePath), data);
            var clip = new ClipItem
            {
                Type = ClipType.Image,
                CreatedAt = _now(),
                ImagePath = relativePath,
                PreviewText = previewText,
                ContentHash = hash,
            };
            return Upsert(clip);
        }
    }

    public void SetPinned(Guid id, bool isPinned)
    {
        lock (_gate)
        {
            var clip = _items.FirstOrDefault(item => item.Id == id);
            if (clip is null)
            {
                return;
            }

            clip.IsPinned = isPinned;
            Save();
        }
    }

    public void MarkCopied(Guid id)
    {
        lock (_gate)
        {
            var index = _items.FindIndex(item => item.Id == id);
            if (index < 0)
            {
                return;
            }

            var clip = _items[index];
            clip.LastCopiedAt = _now();
            _items.RemoveAt(index);
            _items.Insert(0, clip);
            Save();
        }
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            var index = _items.FindIndex(item => item.Id == id);
            if (index < 0)
            {
                return;
            }

            var clip = _items[index];
            _items.RemoveAt(index);
            DeleteImageFileIfNeeded(clip);
            Save();
        }
    }

    public void CleanupExpiredClips()
    {
        lock (_gate)
        {
            var cutoff = _now() - _expiration;
            var expired = _items.Where(item => !item.IsPinned && item.CreatedAt < cutoff).ToArray();
            if (expired.Length == 0)
            {
                return;
            }
            _items.RemoveAll(item => !item.IsPinned && item.CreatedAt < cutoff);
            foreach (var clip in expired)
            {
                DeleteImageFileIfNeeded(clip);
            }

            Save();
        }
    }

    public IReadOnlyList<ClipItem> Clips(string query, ClipFilter filter = ClipFilter.All)
    {
        var normalizedQuery = query.Trim().ToLowerInvariant();
        lock (_gate)
        {
            return _items.Where(clip =>
            {
                var matchesFilter = filter switch
                {
                    ClipFilter.All => true,
                    ClipFilter.Text => clip.Type == ClipType.Text,
                    ClipFilter.Image => clip.Type == ClipType.Image,
                    ClipFilter.Pinned => clip.IsPinned,
                    _ => false,
                };
                var matchesQuery = normalizedQuery.Length == 0
                    || clip.PreviewText.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase)
                    || (clip.Text?.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase) ?? false);
                return matchesFilter && matchesQuery;
            }).ToArray();
        }
    }

    private ClipItem Upsert(ClipItem clip)
    {
        var existing = _items.FirstOrDefault(item => item.ContentHash == clip.ContentHash);
        if (existing is not null)
        {
            return RefreshExisting(existing);
        }

        _items.Insert(0, clip);
        Save();
        return clip;
    }

    private ClipItem RefreshExisting(ClipItem existing)
    {
        var index = _items.FindIndex(item => item.Id == existing.Id);
        if (index < 0)
        {
            return existing;
        }

        _items.RemoveAt(index);
        existing.CreatedAt = _now();
        _items.Insert(0, existing);
        Save();
        return existing;
    }

    private void Save() =>
        AtomicFile.WriteAllBytes(
            _metadataPath,
            JsonSerializer.SerializeToUtf8Bytes(_items, WireJson.IndentedOptions));

    private void DeleteImageFileIfNeeded(ClipItem clip)
    {
        if (clip.ImagePath is null)
        {
            return;
        }

        var path = Path.Combine(StorageDirectory, clip.ImagePath);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
