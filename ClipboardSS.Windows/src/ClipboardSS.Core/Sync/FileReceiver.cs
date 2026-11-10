using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Models;
using System.Text.RegularExpressions;

namespace ClipboardSS.Core.Sync;

public sealed record FileReceiveResult(int StatusCode, string Status, int? Received = null, string? SavedPath = null);

public sealed class FileReceiver : IDisposable
{
    private sealed class Session(FileOfferPayload offer, Guid sourceDeviceId, byte[] key, string path, FileStream stream, DateTimeOffset now)
    {
        public FileOfferPayload Offer { get; } = offer;
        public Guid SourceDeviceId { get; } = sourceDeviceId;
        public byte[] Key { get; } = key;
        public string Path { get; } = path;
        public FileStream Stream { get; } = stream;
        public HashSet<int> Received { get; } = [];
        public long BytesReceived { get; set; }
        public DateTimeOffset LastActivity { get; set; } = now;
    }
    private static readonly Regex TransferIdPattern = new("^[a-z0-9-]{1,64}$", RegexOptions.CultureInvariant);
    private readonly string _tempDirectory;
    private readonly Func<string> _downloadsDirectory;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Dictionary<string, Session> _sessions = new(StringComparer.Ordinal);
    /// <summary>Cancelled transfer id → when it was cancelled; pruned after <see cref="FileTransferConstants.CancelledRetention"/>.</summary>
    private readonly Dictionary<string, DateTimeOffset> _cancelled = new(StringComparer.Ordinal);
    private readonly Func<long> _freeSpace;
    private readonly Func<FileStream, long, byte[], CancellationToken, Task> _writeChunk;
    private readonly SemaphoreSlim _gate = new(1, 1);
    public event Action<FileTransferProgress>? TransferChanged;

    /// <param name="freeSpaceProvider">Bytes available on the transfers volume; defaults to the real drive.</param>
    /// <param name="chunkWriter">Writes one chunk's plaintext at a byte offset (a seam for tests).</param>
    public FileReceiver(string tempDirectory, Func<string> downloadsDirectory, Func<DateTimeOffset>? clock = null,
        Func<long>? freeSpaceProvider = null, Func<FileStream, long, byte[], CancellationToken, Task>? chunkWriter = null)
    {
        _tempDirectory = tempDirectory; _downloadsDirectory = downloadsDirectory; _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Directory.CreateDirectory(tempDirectory);
        _freeSpace = freeSpaceProvider ?? (() => VolumeFreeSpace(tempDirectory));
        _writeChunk = chunkWriter ?? DefaultChunkWriter;
    }

    public static async Task DefaultChunkWriter(FileStream stream, long offset, byte[] bytes, CancellationToken token)
    {
        stream.Position = offset;
        await stream.WriteAsync(bytes, token);
    }

    /// <summary>Free bytes on the drive holding <paramref name="directory"/>; unknown free space does not block transfers.</summary>
    public static long VolumeFreeSpace(string directory)
    {
        try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(directory))!).AvailableFreeSpace; }
        catch { return long.MaxValue; }
    }

    /// <summary>Remembered cancelled ids (test hook for pruning).</summary>
    public int CancelledTransferCount => _cancelled.Count;

    public async Task<FileReceiveResult> OfferAsync(FileOfferPayload offer, byte[] pairKey, Guid sourceDeviceId, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked();
            if (!TransferIdPattern.IsMatch(offer.TransferId)) return new(400, "invalidId");
            var id = Normalize(offer.TransferId);
            if (_sessions.ContainsKey(id)) return new(409, "duplicate");
            if (offer.ChunkSize <= 0 || offer.ChunkSize > FileTransferConstants.MaxChunkSize || offer.FileSize < 0 || offer.ChunkCount < 0 ||
                offer.ChunkCount != offer.FileSize / offer.ChunkSize + (offer.FileSize % offer.ChunkSize == 0 ? 0 : 1)) return new(400, "invalidOffer");
            if (_sessions.Values.Count(s => s.SourceDeviceId == sourceDeviceId) >= FileTransferConstants.MaxSessionsPerDevice)
                return new(429, "tooManyTransfers");
            // The committed term (bytes owed but not yet allocated on disk) is zero here: every
            // active session was preallocated by SetLength, so free space already excludes it.
            if (offer.FileSize > _freeSpace() - FileTransferConstants.FreeSpaceReserve) return new(400, "tooLarge");
            var path = Path.Combine(_tempDirectory, id + ".part");
            var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.RandomAccess);
            try { stream.SetLength(offer.FileSize); }
            catch { stream.Dispose(); TryDelete(path); return new(400, "error"); }
            _cancelled.Remove(id);
            _sessions[id] = new(offer with { TransferId = id }, sourceDeviceId, FileTransferCrypto.DeriveFileKey(pairKey, id), path, stream, _clock());
            TransferChanged?.Invoke(new(id, offer.FileName, 0, offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Active));
            return new(200, "ready");
        } finally { _gate.Release(); }
    }

    /// <summary>
    /// Chunks are unauthenticated at the HTTP layer (anyone who sees <c>X-Transfer-Id</c> can post one),
    /// so a rejected chunk never touches the session: it stays intact for the real sender.
    /// </summary>
    public async Task<FileReceiveResult> ChunkAsync(string transferId, int index, byte[] body, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked(); var id = Normalize(transferId);
            if (!_sessions.TryGetValue(id, out var session)) return _cancelled.ContainsKey(id) ? new(410, "cancelled") : new(404, "unknown");
            if (index < 0 || index >= session.Offer.ChunkCount) return new(400, "badIndex");
            byte[] plaintext;
            try { plaintext = FileTransferCrypto.OpenChunk(session.Key, index, body); }
            catch { return new(400, "decryptFailed"); }
            var expected = index == session.Offer.ChunkCount - 1
                ? checked((int)(session.Offer.FileSize - (long)index * session.Offer.ChunkSize)) : session.Offer.ChunkSize;
            if (plaintext.Length != expected) return new(400, "badSize");
            // The index counts as received only once its bytes are on disk; a retry rewrites it.
            if (!session.Received.Contains(index))
            {
                try { await _writeChunk(session.Stream, (long)index * session.Offer.ChunkSize, plaintext, token); }
                catch (Exception) when (!token.IsCancellationRequested) { return new(400, "writeFailed"); }
                session.Received.Add(index);
                session.BytesReceived += expected;
            }
            session.LastActivity = _clock();
            TransferChanged?.Invoke(new(id, session.Offer.FileName, session.BytesReceived, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Active));
            return new(200, "ok", session.Received.Count);
        } finally { _gate.Release(); }
    }

    public async Task<FileReceiveResult> FinishAsync(string transferId, Guid sourceDeviceId, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked(); var id = Normalize(transferId);
            // Another paired device must not learn of, or finish, this device's transfer.
            if (!_sessions.TryGetValue(id, out var session) || session.SourceDeviceId != sourceDeviceId) return new(404, "unknown");
            if (session.Received.Count != session.Offer.ChunkCount) return new(409, "incomplete");
            string destination;
            try
            {
                session.Stream.Dispose();
                string hash;
                await using (var file = new FileStream(session.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                    hash = await ContentHasher.FileHashAsync(file, token);
                if (!string.Equals(hash, session.Offer.FileHash, StringComparison.OrdinalIgnoreCase)) return FailLocked(id, session, 422, "hashMismatch");
                var downloads = _downloadsDirectory();
                Directory.CreateDirectory(downloads);
                destination = CollisionSafePath(downloads, session.Offer.FileName);
                File.Move(session.Path, destination);
                MarkAsDownloaded(destination);
            }
            catch (Exception) when (!token.IsCancellationRequested) { return FailLocked(id, session, 422, "error"); }
            catch { FailLocked(id, session, 422, "error"); throw; }
            _sessions.Remove(id);
            TransferChanged?.Invoke(new(id, session.Offer.FileName, session.Offer.FileSize, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Completed, destination));
            return new(200, "complete", SavedPath: destination);
        } finally { _gate.Release(); }
    }

    public async Task<FileReceiveResult> CancelAsync(string transferId, Guid sourceDeviceId, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked(); var id = Normalize(transferId);
            if (_sessions.TryGetValue(id, out var owned) && owned.SourceDeviceId != sourceDeviceId) return new(404, "unknown");
            _cancelled[id] = _clock();
            if (_sessions.Remove(id, out var session)) { session.Stream.Dispose(); TryDelete(session.Path); TransferChanged?.Invoke(new(id, session.Offer.FileName, 0, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Cancelled)); }
            return new(200, "cancelled");
        } finally { _gate.Release(); }
    }

    public async Task CleanupExpiredAsync(CancellationToken token = default) { await _gate.WaitAsync(token); try { CleanupExpiredLocked(); } finally { _gate.Release(); } }
    private void CleanupExpiredLocked()
    {
        foreach (var pair in _sessions.Where(p => _clock() - p.Value.LastActivity >= FileTransferConstants.SessionIdleTimeout).ToArray()) { pair.Value.Stream.Dispose(); TryDelete(pair.Value.Path); _sessions.Remove(pair.Key); }
        foreach (var pair in _cancelled.Where(p => _clock() - p.Value >= FileTransferConstants.CancelledRetention).ToArray()) _cancelled.Remove(pair.Key);
    }
    private FileReceiveResult FailLocked(string id, Session session, int code, string status) { session.Stream.Dispose(); TryDelete(session.Path); _sessions.Remove(id); TransferChanged?.Invoke(new(id, session.Offer.FileName, 0, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Failed, Error: status)); return new(code, status); }
    private static string Normalize(string id) => id.ToLowerInvariant();
    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
    private static readonly HashSet<string> ReservedDeviceNames = new(
        ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
         "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"], StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The peer-supplied name reduced to one safe Windows file name: no directory part (either
    /// separator), no <c>:</c> (which would address an alternate data stream) or other invalid
    /// character, no trailing dots/spaces, and no reserved device name (<c>NUL</c>, <c>CON.txt</c>…).
    /// </summary>
    public static string SafeFileName(string name)
    {
        var leaf = name[(name.LastIndexOfAny(['/', '\\']) + 1)..];
        var cleaned = new string(leaf.Where(c => c >= 0x20 && c is not ('<' or '>' or ':' or '"' or '|' or '?' or '*')).ToArray())
            .TrimEnd('.', ' ');
        if (cleaned.Length == 0 || cleaned is "." or "..") return "file";
        var stem = cleaned.Split('.', 2)[0].TrimEnd(' ');
        return ReservedDeviceNames.Contains(stem) ? "_" + cleaned : cleaned;
    }

    /// <summary>
    /// Tags a received file as coming from another computer (Mark of the Web, <c>ZoneId=3</c>) so
    /// SmartScreen and Office treat it as untrusted. NTFS-only and best effort: a failure (FAT32,
    /// network share) never fails the transfer.
    /// </summary>
    private static void MarkAsDownloaded(string path)
    {
        if (!OperatingSystem.IsWindows()) return;
        try { File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n"); }
        catch { }
    }

    private static string CollisionSafePath(string directory, string name) { name = SafeFileName(name); var path = Path.Combine(directory, name); for (var n = 2; File.Exists(path); n++) path = Path.Combine(directory, $"{Path.GetFileNameWithoutExtension(name)} ({n}){Path.GetExtension(name)}"); return path; }
    public void Dispose() { foreach (var session in _sessions.Values) { session.Stream.Dispose(); TryDelete(session.Path); } _gate.Dispose(); }
}
