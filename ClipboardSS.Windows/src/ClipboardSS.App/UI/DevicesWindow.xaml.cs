using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace ClipboardSS.App.UI;

public partial class DevicesWindow : Window
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

    private void Refresh() => PairedList.ItemsSource = _model.PairedDevices.ToArray();

    private void OnClosing(object? sender, CancelEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        _model.StopHostingCode();
        HostCodeText.Text = string.Empty;
        Hide();
    }
}
