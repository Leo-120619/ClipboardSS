using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Selection;

namespace ClipboardSS.App.Capture;

internal sealed class ScreenTextOverlayWindow : Window
{
    private readonly ScreenSnapshot _snapshot;
    private readonly ScreenTextSelectionState _selection;
    private readonly Action _selectionChanged;
    private readonly Action _copy;
    private readonly Action _dismiss;
    private readonly Canvas _canvas = new();
    private Point? _dragStart;
    private bool _dragged;
    private bool _dragExtending;
    private bool _closingFromController;

    public ScreenTextOverlayWindow(
        ScreenSnapshot snapshot,
        ScreenTextSelectionState selection,
        Action selectionChanged,
        Action copy,
        Action dismiss)
    {
        _snapshot = snapshot;
        _selection = selection;
        _selectionChanged = selectionChanged;
        _copy = copy;
        _dismiss = dismiss;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        Focusable = true;
        Content = _canvas;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) =>
        {
            Render();
            Activate();
            Focus();
        };
        SizeChanged += (_, _) => Render();
        PreviewKeyDown += OnPreviewKeyDown;
        _canvas.PreviewMouseLeftButtonDown += Canvas_OnPreviewMouseLeftButtonDown;
        _canvas.PreviewMouseMove += Canvas_OnPreviewMouseMove;
        _canvas.PreviewMouseLeftButtonUp += Canvas_OnPreviewMouseLeftButtonUp;
    }

    public void CloseFromController()
    {
        _closingFromController = true;
        Close();
    }

    public void RefreshSelection() => Render();

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (!_closingFromController) _dismiss();
    }

    private void OnSourceInitialized(object? sender, EventArgs args)
    {
        var handle = new WindowInteropHelper(this).Handle;
        _ = NativeMethods.SetWindowPos(
            handle,
            new IntPtr(NativeMethods.HwndTopmost),
            _snapshot.Bounds.X,
            _snapshot.Bounds.Y,
            _snapshot.Bounds.Width,
            _snapshot.Bounds.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpShowWindow);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key is Key.Enter or Key.Return
            || (args.Key == Key.C && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)))
        {
            args.Handled = true;
            _copy();
            return;
        }
        if (args.Key == Key.Escape)
        {
            args.Handled = true;
            _dismiss();
            return;
        }
        if (args.Key == Key.A && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            args.Handled = true;
            _selection.SelectAll(_snapshot.DisplayId);
            _selectionChanged();
        }
    }

    private void Canvas_OnPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs args)
    {
        if (IsActionControl(args.OriginalSource as DependencyObject)) return;
        _dragStart = PointToScreen(args.GetPosition(_canvas));
        _dragged = false;
        _dragExtending = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        _canvas.CaptureMouse();
    }

    private void Canvas_OnPreviewMouseMove(object sender, MouseEventArgs args)
    {
        if (_dragStart is not { } start || args.LeftButton != MouseButtonState.Pressed) return;
        var end = PointToScreen(args.GetPosition(_canvas));
        if (!_dragged)
        {
            _dragged = Math.Abs(end.X - start.X) >= 4 || Math.Abs(end.Y - start.Y) >= 4;
        }
        if (!_dragged) return;
        if (_dragExtending) _selection.ExtendRange(new PointD(end.X, end.Y));
        else _selection.SelectRange(new PointD(start.X, start.Y), new PointD(end.X, end.Y));
        _selectionChanged();
    }

    private void Canvas_OnPreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs args)
    {
        if (_dragStart is null) return;
        _dragStart = null;
        _canvas.ReleaseMouseCapture();
        if (_dragged) return;
        if (IsActionControl(args.OriginalSource as DependencyObject)) return;

        var id = FindBlockId(args.OriginalSource as DependencyObject);
        if (id is null)
        {
            _selection.ClearSelection();
        }
        else if (args.ClickCount >= 2)
        {
            _selection.SelectLine(id);
        }
        else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            _selection.Toggle(id);
        }
        else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            _selection.Extend(id);
        }
        else
        {
            _selection.Select(id);
        }
        _selectionChanged();
    }

    private void Render()
    {
        if (!IsLoaded || _canvas.ActualWidth <= 0 || _canvas.ActualHeight <= 0) return;
        _canvas.Children.Clear();
        var image = new Image
        {
            Source = LoadImage(_snapshot.PngData),
            Stretch = Stretch.Fill,
            Width = _canvas.ActualWidth,
            Height = _canvas.ActualHeight,
            IsHitTestVisible = false,
        };
        _canvas.Children.Add(image);
        _canvas.Children.Add(new Rectangle
        {
            Width = _canvas.ActualWidth,
            Height = _canvas.ActualHeight,
            Fill = new SolidColorBrush(Color.FromArgb(13, 0, 0, 0)),
            IsHitTestVisible = false,
        });

        var displayBlocks = _selection.Blocks.Where(block => block.DisplayId == _snapshot.DisplayId).ToArray();
        foreach (var group in displayBlocks.Where(block => _selection.SelectedIds.Contains(block.Id))
                     .GroupBy(block => block.LineId ?? block.Id))
        {
            var rect = Union(group.Select(block => block.Bounds));
            AddRibbon(rect);
        }
        foreach (var block in displayBlocks) AddHitTarget(block);
        AddActionBar(displayBlocks.Count(block => _selection.SelectedIds.Contains(block.Id)));
    }

    private void AddRibbon(RectD physicalBounds)
    {
        var rect = ToLocalDip(physicalBounds);
        var ribbon = new Border
        {
            Width = Math.Max(8, rect.Width + 2),
            Height = Math.Max(8, rect.Height + 2),
            Background = new SolidColorBrush(Color.FromArgb(105, 35, 129, 255)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(215, 125, 190, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(2),
            IsHitTestVisible = false,
        };
        Canvas.SetLeft(ribbon, rect.X - 1);
        Canvas.SetTop(ribbon, rect.Y - 1);
        _canvas.Children.Add(ribbon);
    }

    private void AddHitTarget(ScreenTextBlock block)
    {
        var rect = ToLocalDip(block.Bounds);
        var target = new Border
        {
            Tag = block.Id,
            Width = Math.Max(8, rect.Width),
            Height = Math.Max(8, rect.Height),
            Background = Brushes.Transparent,
            Cursor = Cursors.IBeam,
        };
        target.MouseEnter += (_, _) => target.Background = new SolidColorBrush(Color.FromArgb(35, 88, 166, 255));
        target.MouseLeave += (_, _) => target.Background = Brushes.Transparent;
        Canvas.SetLeft(target, rect.X);
        Canvas.SetTop(target, rect.Y);
        _canvas.Children.Add(target);
    }

    private void AddActionBar(int selectedOnDisplay)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock
        {
            Text = selectedOnDisplay > 0 ? $"{selectedOnDisplay} word(s) selected" : "Click, Ctrl-click, or drag to select text",
            Foreground = Brushes.White,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 14, 0),
        });
        var joinMode = new ComboBox { Width = 92, Height = 28, SelectedIndex = _selection.JoinMode == ScreenTextJoinMode.Lines ? 0 : 1 };
        joinMode.Items.Add("Lines");
        joinMode.Items.Add("Spaces");
        joinMode.SelectionChanged += (_, _) =>
        {
            _selection.JoinMode = joinMode.SelectedIndex == 0 ? ScreenTextJoinMode.Lines : ScreenTextJoinMode.Spaces;
            _selectionChanged();
        };
        panel.Children.Add(joinMode);
        panel.Children.Add(ActionButton("Clear", () => { _selection.ClearSelection(); _selectionChanged(); }));
        panel.Children.Add(ActionButton("Cancel", _dismiss));
        var copy = ActionButton("Copy", _copy);
        copy.IsEnabled = _selection.CanCopySelection;
        panel.Children.Add(copy);
        var border = new Border
        {
            Tag = "action-bar",
            Padding = new Thickness(14, 10, 14, 10),
            Background = new SolidColorBrush(Color.FromArgb(232, 24, 28, 36)),
            CornerRadius = new CornerRadius(8),
            Child = panel,
        };
        border.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(border, Math.Max(12, (_canvas.ActualWidth - border.DesiredSize.Width) / 2));
        Canvas.SetTop(border, Math.Max(12, _canvas.ActualHeight - border.DesiredSize.Height - 28));
        _canvas.Children.Add(border);
    }

    private static Button ActionButton(string content, Action action)
    {
        var button = new Button { Content = content, Height = 28, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 0, 10, 0) };
        button.Click += (_, _) => action();
        return button;
    }

    private Rect ToLocalDip(RectD screenBounds) =>
        new PhysicalRect(
            (int)Math.Floor(screenBounds.X),
            (int)Math.Floor(screenBounds.Y),
            Math.Max(1, (int)Math.Ceiling(screenBounds.Width)),
            Math.Max(1, (int)Math.Ceiling(screenBounds.Height))).ToDipRect(this);

    private static RectD Union(IEnumerable<RectD> bounds)
    {
        var items = bounds.ToArray();
        var left = items.Min(item => item.MinX);
        var top = items.Min(item => item.MinY);
        var right = items.Max(item => item.MaxX);
        var bottom = items.Max(item => item.MaxY);
        return new RectD(left, top, right - left, bottom - top);
    }

    private static string? FindBlockId(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is FrameworkElement { Tag: string id } && id != "action-bar") return id;
            source = VisualTreeHelper.GetParent(source);
        }
        return null;
    }

    private static bool IsActionControl(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is Button or ComboBox || source is FrameworkElement { Tag: "action-bar" }) return true;
            source = VisualTreeHelper.GetParent(source);
        }
        return false;
    }

    private static BitmapImage LoadImage(byte[] pngData)
    {
        var image = new BitmapImage();
        using var stream = new MemoryStream(pngData, writable: false);
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }
}
