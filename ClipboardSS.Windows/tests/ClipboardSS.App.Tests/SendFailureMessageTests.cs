using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Tests;

public sealed class SendFailureMessageTests
{
    private static readonly Guid Mac = Guid.Parse("8fb5790c-4533-47bb-90af-827291247fe1");
    private static readonly Guid Phone = Guid.Parse("11111111-4533-47bb-90af-827291247fe1");

    [Fact]
    public void AFailedSendToAnOnlineDeviceIsReported()
    {
        var message = AppModel.UnexpectedSendFailureMessage(
            [new ClipSendFailure(Mac, "MacBook", "timed out"), new ClipSendFailure(Phone, "Phone", "refused")],
            new HashSet<Guid> { Mac });

        Assert.Equal("The last copy did not reach MacBook.", message);
    }

    [Fact]
    public void AFailedSendToAnOfflineDeviceStaysQuiet() =>
        Assert.Null(AppModel.UnexpectedSendFailureMessage(
            [new ClipSendFailure(Phone, "Phone", "timed out")],
            new HashSet<Guid> { Mac }));
}
