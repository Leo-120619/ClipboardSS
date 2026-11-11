using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ClipboardSS.App.Win32;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Storage;

namespace ClipboardSS.App.UI;

public partial class ClipCardControl : UserControl
{
    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(
        nameof(Item),
        typeof(ClipItem),
        typeof(ClipCardControl),
        new PropertyMetadata(null, OnDisplayPropertyChanged));

    public static readonly DependencyProperty StoreProperty = DependencyProperty.Register(
        nameof(Store),
        typeof(ClipStore),
        typeof(ClipCardControl),
        new PropertyMetadata(null, OnDisplayPropertyChanged));

    public static readonly DependencyProperty IsProminentProperty = DependencyProperty.Register(
        nameof(IsProminent),
        typeof(bool),
        typeof(ClipCardControl),
        new PropertyMetadata(false, OnDisplayPropertyChanged));

    private readonly DispatcherTimer _clickTimer;
    private bool _waitingForSecondClick;

    public ClipCardControl()
    {
        InitializeComponent();
        _clickTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(Math.Max(NativeMethods.GetDoubleClickTime(), 200)),
        };
        _clickTimer.Tick += (_, _) => CompleteSingleClick();
    }

    public ClipItem? Item
    {
        get => (ClipItem?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    public ClipStore? Store
    {
        get => (ClipStore?)GetValue(StoreProperty);
        set => SetValue(StoreProperty, value);
    }

    public bool IsProminent
    {
        get => (bool)GetValue(IsProminentProperty);
        set => SetValue(IsProminentProperty, value);
    }

    public event Action<ClipItem>? CopyRequested;
    public event Action<ClipItem>? PinRequested;
    public event Action<ClipItem>? DeleteRequested;
    public event Action<ClipItem>? SinglePasteRequested;
    public event Action<ClipItem>? DoublePasteRequested;

    private static void OnDisplayPropertyChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((ClipCardControl)sender).UpdateDisplay();

    private void UpdateDisplay()
    {
        if (Item is null) return;
        CardBorder.Background = (Brush)FindResource(
            IsProminent ? "ControlFillColorSecondaryBrush" : "CardBackgroundFillColorDefaultBrush");
        PreviewText.Text = Item.PreviewText;
        PreviewText.FontSize = IsProminent ? 16 : 14;
        PreviewText.FontWeight = IsProminent ? FontWeights.SemiBold : FontWeights.Normal;
        PreviewText.MaxHeight = IsProminent ? 80 : 42;
        TypeGlyph.Symbol = Item.Type == ClipType.Text ? Wpf.Ui.Controls.SymbolRegular.TextT24 : Wpf.Ui.Controls.SymbolRegular.Image24;
        PinnedBadge.Visibility = Item.IsPinned ? Visibility.Visible : Visibility.Collapsed;
        PinButton.Content = Item.IsPinned ? "Unpin" : "Pin";
        PinButton.ToolTip = Item.IsPinned ? "Unpin clip" : "Pin clip";
        MetadataText.Text = $"{(Item.Type == ClipType.Text ? "Text" : "Image")} · {RelativeTime(Item.CreatedAt)}";
        AutomationProperties.SetName(ContentHitArea, $"{Item.Type} clip: {Item.PreviewText}");

        if (Item.Type == ClipType.Image && Store is not null)
        {
            ThumbnailImage.Source = ImageThumbnailCache.Load(Item.ResolveImagePath(Store.StorageDirectory));
            ImageContainer.Visibility = ThumbnailImage.Source is null ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            ThumbnailImage.Source = null;
            ImageContainer.Visibility = Visibility.Collapsed;
        }
    }

    private void Content_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs args)
    {
        args.Handled = true;
        if (Item is null) return;
        if (_waitingForSecondClick)
        {
            _clickTimer.Stop();
            _waitingForSecondClick = false;
            DoublePasteRequested?.Invoke(Item);
            return;
        }

        _waitingForSecondClick = true;
        _clickTimer.Start();
    }

    private void Content_OnKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key != Key.Enter || Item is null) return;
        args.Handled = true;
        SinglePasteRequested?.Invoke(Item);
    }

    private void CompleteSingleClick()
    {
        _clickTimer.Stop();
        if (!_waitingForSecondClick || Item is null) return;
        _waitingForSecondClick = false;
        SinglePasteRequested?.Invoke(Item);
    }

    private void Copy_OnClick(object sender, RoutedEventArgs args)
    {
        args.Handled = true;
        if (Item is not null) CopyRequested?.Invoke(Item);
    }

    private void Pin_OnClick(object sender, RoutedEventArgs args)
    {
        args.Handled = true;
        if (Item is not null) PinRequested?.Invoke(Item);
    }

    private void Delete_OnClick(object sender, RoutedEventArgs args)
    {
        args.Handled = true;
        if (Item is not null) DeleteRequested?.Invoke(Item);
    }

    private static string RelativeTime(DateTimeOffset date)
    {
        var elapsed = DateTimeOffset.UtcNow - date.ToUniversalTime();
        if (elapsed < TimeSpan.Zero) return "just now";
        if (elapsed < TimeSpan.FromMinutes(1)) return "just now";
        if (elapsed < TimeSpan.FromHours(1)) return $"{(int)elapsed.TotalMinutes}m ago";
        if (elapsed < TimeSpan.FromDays(1)) return $"{(int)elapsed.TotalHours}h ago";
        if (elapsed < TimeSpan.FromDays(7)) return $"{(int)elapsed.TotalDays}d ago";
        return date.ToLocalTime().ToString("d");
    }
}
