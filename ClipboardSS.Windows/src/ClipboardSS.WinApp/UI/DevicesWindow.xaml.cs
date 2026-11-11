using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace ClipboardSS.App.UI;

public partial class DevicesWindow : Wpf.Ui.Controls.FluentWindow
{
    private readonly AppModel _model;
    private bool _allowClose;

    public DevicesWindow(AppModel model)
    {
        InitializeComponent();
        _model = model;
        _model.StateChanged += (_, _) => Dispatcher.Invoke(Refresh);
        // Raised from timer and server threads: the hosted code ended (spent or expired) or a
        // number to compare appeared, changed or went away.
        _model.PairingStateChanged += (_, _) => Dispatcher.BeginInvoke(RefreshPairing);
        _model.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppModel.VisiblePeers)) Dispatcher.BeginInvoke(RefreshPairing);
        };
        Closing += OnClosing;
        Refresh();
    }

    public void ShowFromTray(Window? owner = null)
    {
        Owner = owner?.IsVisible == true ? owner : null;
        Refresh();
        Show();
        Activate();
    }

    public void CloseForExit()
    {
        _allowClose = true;
        Close();
    }

    private void ShowCode_OnClick(object sender, RoutedEventArgs args)
    {
        _model.ShowPairingCode();
        ErrorText.Text = string.Empty;
        RefreshPairing();
    }

    private async void Join_OnClick(object sender, RoutedEventArgs args)
    {
        if (PeerPicker.SelectedItem is not PeerOption option)
        {
            ErrorText.Text = "Choose the device to pair with.";
            return;
        }

        JoinButton.IsEnabled = false;
        ErrorText.Text = string.Empty;
        try
        {
            var success = await _model.JoinWithCodeAsync(JoinCodeText.Text, option.Peer);
            ErrorText.Text = success ? string.Empty : _model.LastError ?? "Pairing failed.";
            if (success) JoinCodeText.Clear();
        }
        catch (Exception exception)
        {
            ErrorText.Text = exception.Message;
        }
        finally
        {
            JoinButton.IsEnabled = true;
            RefreshPairing();
        }
    }

    private async void ConfirmComparison_OnClick(object sender, RoutedEventArgs args)
    {
        ErrorText.Text = string.Empty;
        if (_model.PairingCoordinator.HostComparison is not null)
        {
            _model.ConfirmHostedPairing();
            return;
        }

        ConfirmComparisonButton.IsEnabled = false;
        var success = await _model.ConfirmJoinAsync();
        // A cancel while waiting leaves LastError empty.
        ErrorText.Text = success ? string.Empty : _model.LastError ?? string.Empty;
        Refresh();
        RefreshPairing();
    }

    private void CancelComparison_OnClick(object sender, RoutedEventArgs args)
    {
        if (_model.PairingCoordinator.HostComparison is not null) _model.CancelHostedPairing();
        else _model.CancelJoin();
        RefreshPairing();
    }

    private async void Scan_OnClick(object sender, RoutedEventArgs args)
    {
        try { await _model.ScanForDevicesAsync(); }
        catch (Exception exception) { ErrorText.Text = exception.Message; }
    }

    /// <summary>Shows the number to compare, or the hosted code (hidden once spent or expired) and the device picker.</summary>
    private void RefreshPairing()
    {
        var coordinator = _model.PairingCoordinator;
        var comparison = coordinator.HostComparison ?? coordinator.JoinComparison;
        if (comparison is not null)
        {
            HostingPanel.Visibility = Visibility.Collapsed;
            JoinPanel.Visibility = Visibility.Collapsed;
            ComparisonPanel.Visibility = Visibility.Visible;
            ComparisonNamesText.Text = $"{coordinator.Identity.Name} \u2194 {comparison.DeviceName}";
            ComparisonHintText.Text = $"Check that {comparison.DeviceName} shows the same number:";
            ComparisonCodeText.Text = comparison.ConfirmCode;
            ComparisonWaitingText.Text = $"Waiting for {comparison.DeviceName} to confirm\u2026";
            ComparisonWaitingText.Visibility = comparison.LocalConfirmed ? Visibility.Visible : Visibility.Collapsed;
            ConfirmComparisonButton.IsEnabled = !comparison.LocalConfirmed;
            return;
        }

        var hostCode = coordinator.HostCode;
        ComparisonPanel.Visibility = Visibility.Collapsed;
        HostingPanel.Visibility = Visibility.Visible;
        HostCodeText.Text = hostCode ?? string.Empty;
        JoinPanel.Visibility = hostCode is null ? Visibility.Visible : Visibility.Collapsed;

        var selectedId = (PeerPicker.SelectedItem as PeerOption)?.Peer.Id;
        var options = _model.PairingCandidates.Select(peer => new PeerOption(peer)).ToArray();
        PeerPicker.ItemsSource = options;
        PeerPicker.SelectedItem = options.FirstOrDefault(option => option.Peer.Id == selectedId);
        ScanButton.IsEnabled = !_model.IsScanning;
        ScanButton.Content = _model.IsScanning ? "Scanning\u2026" : "Scan network";
    }

    private void Unpair_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: Guid id }) _model.Unpair(id);
        Refresh();
    }

    private async void ToggleConnected_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: Guid id })
            await _model.SetConnectedAsync(id, !_model.IsDeviceConnectionActive(id));
        Refresh();
    }

    private void CancelTransfer_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: string id }) _model.CancelTransfer(id);
    }

    private void OpenLocation_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: string path } || string.IsNullOrWhiteSpace(path)) return;
        try
        {
            var arguments = File.Exists(path)
                ? $"/select,\"{path}\""
                : $"\"{Path.GetDirectoryName(path)}\"";
            Process.Start(new ProcessStartInfo("explorer.exe", arguments) { UseShellExecute = true });
        }
        catch (Exception exception)
        {
            ErrorText.Text = $"Could not open file location: {exception.Message}";
        }
    }

    private async void SendFile_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: Guid id }) return;
        var picker = new OpenFileDialog { Title = "Send a file", CheckFileExists = true };
        if (picker.ShowDialog(this) != true) return;
        ErrorText.Text = string.Empty;
        try { await _model.SendFileAsync(picker.FileName, id); }
        catch (Exception exception) { ErrorText.Text = exception.Message; }
    }

    private void Refresh()
    {
        PairedList.ItemsSource = _model.PairedDevices
            .Select(device => new PairedDeviceRow(
                device.Id,
                device.Name,
                device.Host,
                _model.IsDeviceConnectionActive(device.Id),
                _model.IsDeviceOnline(device.Id),
                _model.DeviceNeedsUpdate(device.Id),
                _model.DeviceClockSkewed(device.Id)))
            .ToArray();
        TransferList.ItemsSource = _model.Transfers.ToArray();
        RefreshPairing();
    }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        _model.StopHostingCode();
        _model.CancelJoin();
        RefreshPairing();
        Hide();
    }
}

/// <summary>A device offered for pairing in the picker.</summary>
internal sealed record PeerOption(ClipboardSS.Core.Models.Peer Peer)
{
    public override string ToString() => $"{Peer.Name} ({Peer.Host})";
}

internal sealed record PairedDeviceRow(
    Guid Id, string Name, string? Host, bool Connected, bool Online, bool NeedsUpdate, bool ClockSkewed = false)
{
    public string ConnectActionLabel => Connected ? "Disconnect" : "Connect";
    public string StatusText =>
        (Online ? "Online" : "Offline")
        + (ClockSkewed ? " · Clock out of sync" : "")
        + (NeedsUpdate ? " · Needs update" : "");
    public Brush StatusBrush => NeedsUpdate || ClockSkewed ? Brushes.Orange : Online ? Brushes.LimeGreen : Brushes.Gray;
    public bool CanSend => Connected && !NeedsUpdate;
}
