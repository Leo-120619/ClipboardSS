namespace ClipboardSS.Core.Models;

/// <summary>Wire protocol version shared by envelopes, mDNS TXT <c>v</c> and <c>/v1/id</c> <c>v</c>.</summary>
public static class WireProtocol
{
    public const int Version = 2;

    /// <summary>User-facing text for a peer that runs another wire protocol version.</summary>
    public const string UpdateOtherDeviceMessage = "Update ClipboardSS on the other device to keep syncing.";

    /// <summary>User-facing text for peers that answered <c>400 {"status":"stale"}</c>.</summary>
    public static string ClockOutOfSyncMessage(IEnumerable<string> deviceNames) =>
        $"Clock out of sync with {string.Join(", ", deviceNames)}.";

    /// <summary>True for <c>400 {"status":"stale"}</c>: the peer's clock disagrees with ours.</summary>
    public static bool IsStaleResponse(int statusCode, byte[] body)
    {
        if (statusCode != 400) return false;
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(body);
            return document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                document.RootElement.TryGetProperty("status", out var status) &&
                status.ValueKind == System.Text.Json.JsonValueKind.String &&
                status.GetString() == "stale";
        }
        catch (System.Text.Json.JsonException)
        {
            return false;
        }
    }
}

/// <summary>Raised when a peer advertises an older protocol or answers 426.</summary>
public sealed class PeerNeedsUpdateException() : Exception(WireProtocol.UpdateOtherDeviceMessage);

/// <summary>Raised when a peer answers <c>400 {"status":"stale"}</c>: its clock disagrees with ours.</summary>
public sealed class PeerClockOutOfSyncException(string deviceName)
    : Exception(WireProtocol.ClockOutOfSyncMessage([deviceName]))
{
    public string DeviceName { get; } = deviceName;
}
