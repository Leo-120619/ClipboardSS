using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
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
        HostCodeText.Text = _model.ShowPairingCode();
        ErrorText.Text = string.Empty;
    }

    private async void Join_OnClick(object sender, RoutedEventArgs args)
    {
        JoinButton.IsEnabled = false;
        ErrorText.Text = string.Empty;
        try
        {
            var success = await _model.JoinWithCodeAsync(JoinCodeText.Text);
            ErrorText.Text = success ? string.Empty : _model.LastError ?? "Pairing failed.";
            if (success) JoinCodeText.Clear();
            Refresh();
        }
        catch (Exception exception)
        {
            ErrorText.Text = exception.Message;
        }
        finally
        {
            JoinButton.IsEnabled = true;
        }
    }

    private void Unpair_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: Guid id }) _model.Unpair(id);
        Refresh();
    }

    private void Connected_OnClick(object sender, RoutedEventArgs args)
    {
        if (sender is CheckBox { Tag: Guid id } checkBox) _model.SetConnected(id, checkBox.IsChecked == true);
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

    private void Refresh() { PairedList.ItemsSource = _model.PairedDevices.ToArray(); TransferList.ItemsSource = _model.Transfers.ToArray(); }

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        _model.StopHostingCode();
        HostCodeText.Text = string.Empty;
        Hide();
    }
}
