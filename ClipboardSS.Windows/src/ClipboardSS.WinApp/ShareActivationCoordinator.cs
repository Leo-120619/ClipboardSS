using System.Windows;
using ClipboardSS.App.UI;
using ClipboardSS.Core.Models;
using Windows.ApplicationModel.DataTransfer;
using Windows.ApplicationModel.DataTransfer.ShareTarget;
using Windows.Storage;

namespace ClipboardSS.App;

public sealed class ShareActivationCoordinator
{
    private readonly AppModel _model;
    private readonly Func<Window?> _owner;
    private readonly Action _openDevices;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public ShareActivationCoordinator(AppModel model, Func<Window?> owner, Action openDevices)
    {
        _model = model;
        _owner = owner;
        _openDevices = openDevices;
    }

    public async Task HandleAsync(ShareOperation operation)
    {
        await _gate.WaitAsync();
        var staged = new List<string>();
        try
        {
            operation.ReportStarted();
            if (!operation.Data.Contains(StandardDataFormats.StorageItems))
                throw new InvalidOperationException("ClipboardSS can only receive shared files.");

            var items = await operation.Data.GetStorageItemsAsync();
            if (items.Count == 0) throw new InvalidOperationException("No files were included in this share.");
            var paths = new List<string>();
            foreach (var item in items)
            {
                if (item is StorageFile file)
                {
                    var copy = await file.CopyAsync(
                        ApplicationData.Current.TemporaryFolder,
                        file.Name,
                        NameCollisionOption.GenerateUniqueName);
                    staged.Add(copy.Path);
                    paths.Add(copy.Path);
                }
                else if (item is StorageFolder folder && Directory.Exists(folder.Path))
                {
                    // Folders are read in place and zipped when sent; the app runs full trust.
                    paths.Add(folder.Path);
                }
                else
                {
                    throw new InvalidOperationException($"\"{item.Name}\" cannot be read.");
                }
            }
            operation.ReportDataRetrieved();

            var deviceId = await ChooseTargetAsync(paths);
            if (deviceId is null) throw new OperationCanceledException("The share was cancelled.");
            await _model.SendFilesAsync(paths, deviceId.Value);
            operation.ReportCompleted();
        }
        catch (OperationCanceledException)
        {
            TryReportError(operation, "The share was cancelled.");
        }
        catch (Exception exception)
        {
            TryReportError(operation, $"ClipboardSS could not share these files: {exception.Message}");
            _model.ReportError(exception.Message);
        }
        finally
        {
            ShareFileStaging.DeleteFiles(staged);
            _gate.Release();
        }
    }

    private static void TryReportError(ShareOperation operation, string message)
    {
        try { operation.ReportError(message); }
        catch (Exception) { }
    }

    private async Task<Guid?> ChooseTargetAsync(IReadOnlyList<string> paths)
    {
        var targets = AppModel.ComposeSendTargets(_model.VisiblePeers, _model.PairedDevices);
        if (targets.Count == 1) return targets[0].Id;

        var picker = new ShareTargetWindow(_model, paths);
        var owner = _owner();
        if (owner?.IsVisible == true) picker.Owner = owner;
        picker.PairingRequested += (_, _) => _openDevices();
        return await picker.ChooseAsync();
    }
}

public static class ShareFileStaging
{
    public static void DeleteFiles(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
