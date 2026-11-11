using ClipboardSS.App.UI;

namespace ClipboardSS.App.Tests;

public sealed class RelativeTimeTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 11, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(0, "just now")]
    [InlineData(59, "just now")]
    [InlineData(60, "1 min. ago")]
    [InlineData(20 * 60, "20 min. ago")]
    [InlineData(3 * 3600, "3 hr. ago")]
    [InlineData(24 * 3600, "1 day ago")]
    [InlineData(3 * 24 * 3600, "3 days ago")]
    public void FormatsElapsedTimeLikeTheMacCards(int secondsAgo, string expected) =>
        Assert.Equal(expected, ClipCardControl.RelativeTime(Now.AddSeconds(-secondsAgo), Now));

    [Fact]
    public void AClipFromTheFutureIsJustNow() =>
        Assert.Equal("just now", ClipCardControl.RelativeTime(Now.AddMinutes(5), Now));
}
