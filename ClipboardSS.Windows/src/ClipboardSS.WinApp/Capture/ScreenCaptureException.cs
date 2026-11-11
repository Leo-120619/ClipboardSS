namespace ClipboardSS.App.Capture;

public sealed class ScreenCaptureCancelledException : OperationCanceledException
{
    public ScreenCaptureCancelledException()
        : base("Screenshot capture was cancelled.")
    {
    }
}
