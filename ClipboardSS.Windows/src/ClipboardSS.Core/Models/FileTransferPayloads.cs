namespace ClipboardSS.Core.Models;

public static class FileTransferConstants
{
    public const int ChunkSize = 4 * 1024 * 1024;
    public const int MaxChunkSize = 4 * 1024 * 1024;
    public static readonly TimeSpan SessionIdleTimeout = TimeSpan.FromSeconds(60);
}

public sealed record FileOfferPayload(string TransferId, string FileName, long FileSize,
    string MimeType, string FileHash, int ChunkSize, int ChunkCount,
    DateTimeOffset CreatedAt, string SourceDeviceName);
public sealed record FileFinishPayload(string TransferId);
public sealed record FileCancelPayload(string TransferId);

public enum FileTransferDirection { Sending, Receiving }
public enum FileTransferStatus { Active, Completed, Cancelled, Failed }
public sealed record FileTransferProgress(string TransferId, string FileName, long BytesTransferred,
    long TotalBytes, FileTransferDirection Direction, FileTransferStatus Status,
    string? SavedPath = null, string? Error = null);
