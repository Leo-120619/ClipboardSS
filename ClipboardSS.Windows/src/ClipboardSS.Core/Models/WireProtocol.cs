namespace ClipboardSS.Core.Models;

/// <summary>Wire protocol version shared by envelopes, mDNS TXT <c>v</c> and <c>/v1/id</c> <c>v</c>.</summary>
public static class WireProtocol
{
    public const int Version = 2;

    /// <summary>User-facing text for a peer that runs another wire protocol version.</summary>
    public const string UpdateOtherDeviceMessage = "Update ClipboardSS on the other device to keep syncing.";
}

/// <summary>Raised when a peer advertises an older protocol or answers 426.</summary>
public sealed class PeerNeedsUpdateException() : Exception(WireProtocol.UpdateOtherDeviceMessage);
