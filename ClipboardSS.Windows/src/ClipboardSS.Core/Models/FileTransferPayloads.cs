namespace ClipboardSS.Core.Models;

public static class FileTransferConstants
{
    public const int ChunkSize = 4 * 1024 * 1024;
    public const int MaxChunkSize = 4 * 1024 * 1024;
    public static readonly TimeSpan SessionIdleTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Free space an offer must leave on the transfers volume: 500 MB (MiB, 524,288,000 bytes).</summary>
    public const long FreeSpaceReserve = 500L * 1024 * 1024;
    /// <summary>Most concurrent receive sessions one source device may hold.</summary>
    public const int MaxSessionsPerDevice = 8;
    /// <summary>How long a cancelled transfer id is remembered (chunks for it get 410).</summary>
    public static readonly TimeSpan CancelledRetention = TimeSpan.FromSeconds(600);

    /// <summary>
    /// How long a sender waits for <c>/v1/file/finish</c>, which the receiver answers only after
    /// hashing the whole file: 1 s per 20 MiB, at least 30 s, at most 600 s (4 GiB → 205 s).
    /// </summary>
    public static TimeSpan FinishTimeout(long fileSize)
    {
        const long perSecond = 20L * 1024 * 1024;
        var seconds = (Math.Max(0, fileSize) + perSecond - 1) / perSecond;
        return TimeSpan.FromSeconds(Math.Clamp(seconds, 30, 600));
    }
}

public sealed record FileOfferPayload(string TransferId, string FileName, long FileSize,
    string MimeType, string FileHash, int ChunkSize, int ChunkCount,
    DateTimeOffset CreatedAt, string SourceDeviceName);
public sealed record FileFinishPayload(string TransferId);
public sealed record FileCancelPayload(string TransferId);

public enum FileTransferDirection { Sending, Receiving }
/// <summary><see cref="Unconfirmed"/>: sent, but the receiver did not confirm in time; it may still have saved the file.</summary>
public enum FileTransferStatus { Active, Completed, Cancelled, Failed, Unconfirmed }

/// <summary>How a file send ended when it did not throw.</summary>
public enum FileSendOutcome
{
    /// <summary>The receiver confirmed it saved the file.</summary>
    Delivered,
    /// <summary>
    /// Every chunk was delivered but <c>/v1/file/finish</c> timed out. The receiver may still have
    /// saved the file, so this is not a failure, and no cancel is sent.
    /// </summary>
    Unconfirmed,
}
public sealed record FileTransferProgress(string TransferId, string FileName, long BytesTransferred,
    long TotalBytes, FileTransferDirection Direction, FileTransferStatus Status,
    string? SavedPath = null, string? Error = null);
