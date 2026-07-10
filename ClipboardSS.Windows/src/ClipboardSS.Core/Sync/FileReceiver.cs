using ClipboardSS.Core.Crypto;
using ClipboardSS.Core.Models;

namespace ClipboardSS.Core.Sync;

public sealed record FileReceiveResult(int StatusCode, string Status, int? Received = null, string? SavedPath = null);

public sealed class FileReceiver : IDisposable
{
    private sealed class Session(FileOfferPayload offer, byte[] key, string path, DateTimeOffset now)
    {
        public FileOfferPayload Offer { get; } = offer;
        public byte[] Key { get; } = key;
        public string Path { get; } = path;
        public HashSet<int> Received { get; } = [];
        public DateTimeOffset LastActivity { get; set; } = now;
    }
    private readonly string _tempDirectory;
    private readonly Func<string> _downloadsDirectory;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Dictionary<string, Session> _sessions = new(StringComparer.Ordinal);
    private readonly HashSet<string> _cancelled = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _gate = new(1, 1);
    public event Action<FileTransferProgress>? TransferChanged;

    public FileReceiver(string tempDirectory, Func<string> downloadsDirectory, Func<DateTimeOffset>? clock = null)
    { _tempDirectory = tempDirectory; _downloadsDirectory = downloadsDirectory; _clock = clock ?? (() => DateTimeOffset.UtcNow); Directory.CreateDirectory(tempDirectory); }

    public async Task<FileReceiveResult> OfferAsync(FileOfferPayload offer, byte[] pairKey, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked();
            var id = Normalize(offer.TransferId);
            if (_sessions.ContainsKey(id)) return new(409, "duplicate");
            if (offer.ChunkSize != FileTransferConstants.ChunkSize || offer.FileSize < 0 || offer.ChunkCount < 0 ||
                offer.ChunkCount != (offer.FileSize + offer.ChunkSize - 1) / offer.ChunkSize) return new(400, "invalidOffer");
            var path = Path.Combine(_tempDirectory, id + ".part");
            await using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous))
                file.SetLength(offer.FileSize);
            _cancelled.Remove(id);
            _sessions[id] = new(offer with { TransferId = id }, FileTransferCrypto.DeriveFileKey(pairKey, id), path, _clock());
            TransferChanged?.Invoke(new(id, offer.FileName, 0, offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Active));
            return new(200, "ready");
        } finally { _gate.Release(); }
    }

    public async Task<FileReceiveResult> ChunkAsync(string transferId, int index, byte[] body, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked(); var id = Normalize(transferId);
            if (!_sessions.TryGetValue(id, out var session)) return _cancelled.Contains(id) ? new(410, "cancelled") : new(404, "unknown");
            if (index < 0 || index >= session.Offer.ChunkCount) return FailLocked(id, session, 400, "badIndex");
            byte[] plaintext;
            try { plaintext = FileTransferCrypto.OpenChunk(session.Key, index, body); }
            catch { return FailLocked(id, session, 400, "decryptFailed"); }
            var expected = index == session.Offer.ChunkCount - 1
                ? checked((int)(session.Offer.FileSize - (long)index * session.Offer.ChunkSize)) : session.Offer.ChunkSize;
            if (plaintext.Length != expected) return FailLocked(id, session, 400, "badSize");
            if (!session.Received.Contains(index))
            {
                await using var file = new FileStream(session.Path, FileMode.Open, FileAccess.Write, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.RandomAccess);
                file.Position = (long)index * session.Offer.ChunkSize;
                await file.WriteAsync(plaintext, token);
                session.Received.Add(index);
            }
            session.LastActivity = _clock();
            var bytes = session.Received.Sum(i => i == session.Offer.ChunkCount - 1 ? expected : session.Offer.ChunkSize);
            TransferChanged?.Invoke(new(id, session.Offer.FileName, bytes, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Active));
            return new(200, "ok", session.Received.Count);
        } finally { _gate.Release(); }
    }

    public async Task<FileReceiveResult> FinishAsync(string transferId, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            CleanupExpiredLocked(); var id = Normalize(transferId);
            if (!_sessions.TryGetValue(id, out var session)) return new(404, "unknown");
            if (session.Received.Count != session.Offer.ChunkCount) return new(409, "incomplete");
            string hash;
            await using (var file = new FileStream(session.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                hash = await ContentHasher.FileHashAsync(file, token);
            if (!string.Equals(hash, session.Offer.FileHash, StringComparison.OrdinalIgnoreCase)) return FailLocked(id, session, 422, "hashMismatch");
            Directory.CreateDirectory(_downloadsDirectory());
            var destination = CollisionSafePath(_downloadsDirectory(), session.Offer.FileName);
            File.Move(session.Path, destination);
            _sessions.Remove(id);
            TransferChanged?.Invoke(new(id, session.Offer.FileName, session.Offer.FileSize, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Completed, destination));
            return new(200, "complete", SavedPath: destination);
        } finally { _gate.Release(); }
    }

    public async Task<FileReceiveResult> CancelAsync(string transferId, CancellationToken token = default)
    {
        await _gate.WaitAsync(token); try
        {
            var id = Normalize(transferId); _cancelled.Add(id);
            if (_sessions.Remove(id, out var session)) { TryDelete(session.Path); TransferChanged?.Invoke(new(id, session.Offer.FileName, 0, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Cancelled)); }
            return new(200, "cancelled");
        } finally { _gate.Release(); }
    }

    public async Task CleanupExpiredAsync(CancellationToken token = default) { await _gate.WaitAsync(token); try { CleanupExpiredLocked(); } finally { _gate.Release(); } }
    private void CleanupExpiredLocked() { foreach (var pair in _sessions.Where(p => _clock() - p.Value.LastActivity >= FileTransferConstants.SessionIdleTimeout).ToArray()) { TryDelete(pair.Value.Path); _sessions.Remove(pair.Key); } }
    private FileReceiveResult FailLocked(string id, Session session, int code, string status) { TryDelete(session.Path); _sessions.Remove(id); TransferChanged?.Invoke(new(id, session.Offer.FileName, 0, session.Offer.FileSize, FileTransferDirection.Receiving, FileTransferStatus.Failed, Error: status)); return new(code, status); }
    private static string Normalize(string id) => id.ToLowerInvariant();
    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
    private static string CollisionSafePath(string directory, string name) { name = Path.GetFileName(name); var path = Path.Combine(directory, name); for (var n = 2; File.Exists(path); n++) path = Path.Combine(directory, $"{Path.GetFileNameWithoutExtension(name)} ({n}){Path.GetExtension(name)}"); return path; }
    public void Dispose() { foreach (var session in _sessions.Values) TryDelete(session.Path); _gate.Dispose(); }
}
