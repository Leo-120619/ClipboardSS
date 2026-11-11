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
    private bool _pressed;

    public ClipCardControl()
    {
        InitializeComponent();
        _clickTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(Math.Max(NativeMethods.GetDoubleClickTime(), 200)),
        };
        _clickTimer.Tick += (_, _) => CompleteSingleClick();
        Loaded += (_, _) => RefreshMetadata();
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
        // A recycled container must not carry a half-finished click over to another clip.
        _clickTimer.Stop();
        _waitingForSecondClick = false;
        _pressed = false;
        if (Item is null) return;
        // Resource references, not one-off lookups, so the card follows a light/dark theme change.
        CardBorder.SetResourceReference(
            Border.BackgroundProperty,
            IsProminent ? "ProminentClipCardBrush" : "ClipCardBrush");
        PreviewText.Text = Item.PreviewText;
        PreviewText.FontSize = IsProminent ? 16 : 14;
        PreviewText.FontWeight = IsProminent ? FontWeights.SemiBold : FontWeights.Normal;
        // Four lines for the latest clip, two for history, like the Mac cards.
        PreviewText.LineHeight = IsProminent ? 22 : 20;
        PreviewText.MaxHeight = IsProminent ? 88 : 40;
        TypeGlyph.Symbol = Item.Type == ClipType.Text
            ? Wpf.Ui.Controls.SymbolRegular.TextAlignLeft24
            : Wpf.Ui.Controls.SymbolRegular.Image24;
        PinnedBadge.Visibility = Item.IsPinned ? Visibility.Visible : Visibility.Collapsed;
        PinGlyph.Symbol = Item.IsPinned
            ? Wpf.Ui.Controls.SymbolRegular.PinOff24
            : Wpf.Ui.Controls.SymbolRegular.Pin24;
        PinButton.ToolTip = Item.IsPinned ? "Unpin clip" : "Pin clip";
        AutomationProperties.SetName(PinButton, Item.IsPinned ? "Unpin clip" : "Pin clip");
        RefreshMetadata();
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

    /// <summary>Re-renders the relative time, which goes stale while the list itself is unchanged.</summary>
    public void RefreshMetadata()
    {
        if (Item is null) return;
        MetadataText.Text = $"{(Item.Type == ClipType.Text ? "Text" : "Image")} • {RelativeTime(Item.CreatedAt, DateTimeOffset.UtcNow)}";
    }

    private void Content_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs args) => _pressed = true;

    private void Content_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs args)
    {
        args.Handled = true;
        // Only a press that started on this card counts, not a drag released over it.
        if (!_pressed || Item is null) return;
        _pressed = false;
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

    private void Paste_OnClick(object sender, RoutedEventArgs args)
    {
        args.Handled = true;
        if (Item is not null) SinglePasteRequested?.Invoke(Item);
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

    /// <summary>Short relative time in the Mac card's style: "20 min. ago", "3 hr. ago".</summary>
    public static string RelativeTime(DateTimeOffset date, DateTimeOffset now)
    {
        var elapsed = now.ToUniversalTime() - date.ToUniversalTime();
        if (elapsed < TimeSpan.FromMinutes(1)) return "just now";
        if (elapsed < TimeSpan.FromHours(1)) return $"{(int)elapsed.TotalMinutes} min. ago";
        if (elapsed < TimeSpan.FromDays(1)) return $"{(int)elapsed.TotalHours} hr. ago";
        if (elapsed < TimeSpan.FromDays(7))
        {
            var days = (int)elapsed.TotalDays;
            return days == 1 ? "1 day ago" : $"{days} days ago";
        }
        return date.ToLocalTime().ToString("d");
    }
}
