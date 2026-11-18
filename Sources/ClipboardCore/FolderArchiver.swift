import Foundation

/// Turns a folder into a single `.zip` so it can travel through the one-file transfer
/// protocol; every receiver (Mac, Windows, phone) gets an ordinary zip file.
public enum FolderArchiver {
    /// True when `url` is a directory (including packages such as `.app` or `.rtfd`).
    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Zips `directory` into `destinationDirectory` as `<folder name>.zip` (made unique if
    /// taken) and returns the archive's URL. The archive holds the folder itself at its root.
    public static func zip(_ directory: URL, into destinationDirectory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let folderName = directory.lastPathComponent.isEmpty ? "Folder" : directory.lastPathComponent
        var destination = destinationDirectory.appendingPathComponent("\(folderName).zip")
        var counter = 2
        while files.fileExists(atPath: destination.path) {
            destination = destinationDirectory.appendingPathComponent("\(folderName)-\(counter).zip")
            counter += 1
        }

        // Reading a folder "for uploading" makes the system write a temporary zip of it,
        // which exists only for the duration of the block.
        var coordinationError: NSError?
        var outcome: Result<URL, Error> = .failure(FolderArchiveError.archiveFailed)
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { archive in
            do {
                try files.moveItem(at: archive, to: destination)
                outcome = .success(destination)
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }
}

public enum FolderArchiveError: Error {
    case archiveFailed
}
