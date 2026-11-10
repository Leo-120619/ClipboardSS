using System.Globalization;

namespace ClipboardSS.Core.Storage;

/// <summary>
/// Moves an unreadable state file aside so the app can start with empty state instead of refusing to launch.
/// The copy is kept next to the original as <c>&lt;name&gt;.corrupt-&lt;yyyyMMdd-HHmmss UTC&gt;</c>
/// (same format on every platform).
/// </summary>
public static class CorruptStateFile
{
    public static string Timestamp(DateTimeOffset now) =>
        now.UtcDateTime.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    /// <summary>Renames <paramref name="path"/> to its quarantine name and returns the new path. Never overwrites an earlier copy.</summary>
    public static string Quarantine(string path, DateTimeOffset now)
    {
        var basePath = $"{path}.corrupt-{Timestamp(now)}";
        var destination = basePath;
        for (var suffix = 2; File.Exists(destination); suffix++)
        {
            destination = $"{basePath}-{suffix}";
        }

        File.Move(path, destination);
        return destination;
    }
}
