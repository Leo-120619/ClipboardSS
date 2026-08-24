using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using ClipboardSS.App.Win32;
using Forms = System.Windows.Forms;

namespace ClipboardSS.App.Capture;

public partial class RegionSelectWindow : Window
{
    private readonly Forms.Screen _screen;
    private Point? _dragStart;

    public RegionSelectWindow(Forms.Screen screen)
    {
        InitializeComponent();
        _screen = screen;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => Focus();
    }

    public event EventHandler<PhysicalRect>? RegionSelected;
    public event EventHandler? SelectionCancelled;

    public static Task<PhysicalRect> SelectRegionAsync(CancellationToken cancellationToken = default)
    {
        var completion = new TaskCompletionSource<PhysicalRect>(TaskCreationOptions.RunContinuationsAsynchronously);
        var windows = new List<RegionSelectWindow>();
        var finished = 0;

        void Finish(PhysicalRect? result)
        {
            if (Interlocked.Exchange(ref finished, 1) != 0) return;
            foreach (var window in windows.ToArray()) window.Close();
            if (result is { } region) completion.TrySetResult(region);
            else completion.TrySetException(new ScreenCaptureCancelledException());
        }

        foreach (var screen in Forms.Screen.AllScreens)
        {
            var window = new RegionSelectWindow(screen);
            window.RegionSelected += (_, region) => Finish(region);
            window.SelectionCancelled += (_, _) => Finish(null);
            windows.Add(window);
        }

        cancellationToken.Register(() =>
            System.Windows.Application.Current.Dispatcher.BeginInvoke(() => Finish(null)));
        foreach (var window in windows) window.Show();
        return completion.Task;
    }

    private void OnSourceInitialized(object? sender, EventArgs args)
    {
        var bounds = _screen.Bounds;
        var handle = new WindowInteropHelper(this).Handle;
        _ = NativeMethods.SetWindowPos(
            handle,
            new IntPtr(NativeMethods.HwndTopmost),
            bounds.X,
            bounds.Y,
            bounds.Width,
            bounds.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpShowWindow);
    }

    private void Root_OnPreviewKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key != Key.Escape) return;
        args.Handled = true;
        SelectionCancelled?.Invoke(this, EventArgs.Empty);
    }

    private void Root_OnPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs args)
    {
        _dragStart = args.GetPosition(Root);
        SelectionBorder.Visibility = Visibility.Visible;
        Root.CaptureMouse();
        args.Handled = true;
    }

    private void Root_OnPreviewMouseMove(object sender, MouseEventArgs args)
    {
        if (_dragStart is not { } start || args.LeftButton != MouseButtonState.Pressed) return;
        DrawSelection(start, args.GetPosition(Root));
    }

    private void Root_OnPreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs args)
    {
        if (_dragStart is not { } start) return;
        var end = args.GetPosition(Root);
        _dragStart = null;
        Root.ReleaseMouseCapture();
        var startScreen = PointToScreen(start);
        var endScreen = PointToScreen(end);
        var region = PhysicalRect.FromScreenPoints(startScreen, endScreen);
        if (region.IsUsable) RegionSelected?.Invoke(this, region);
        else SelectionCancelled?.Invoke(this, EventArgs.Empty);
        args.Handled = true;
    }

    private void DrawSelection(Point start, Point end)
    {
        var left = Math.Min(start.X, end.X);
        var top = Math.Min(start.Y, end.Y);
        Canvas.SetLeft(SelectionBorder, left);
        Canvas.SetTop(SelectionBorder, top);
        SelectionBorder.Width = Math.Abs(end.X - start.X);
        SelectionBorder.Height = Math.Abs(end.Y - start.Y);
    }
}
