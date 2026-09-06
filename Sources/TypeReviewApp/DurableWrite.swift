import Foundation

/// Writes a file so that a crash cannot leave a half-written one behind.
///
/// `Data.write(.atomic)` is not enough on its own: it renames without
/// flushing, so a power loss between the rename and the flush can leave a
/// zero-length file where a typing history was. The sequence that survives it
/// is write to a temp file, `F_FULLFSYNC` that file's descriptor, then replace
/// the destination — and both stores in this app need exactly that, which is
/// why it is written once here rather than twice.
///
/// The temp file is removed on every failure path. Leaving it behind meant a
/// disk that was full, or a directory that had become unwritable, accumulated
/// a `.tmp` beside the user's profile on each attempt.
func writeDurably(_ data: Data, to destination: URL, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temp = directory.appendingPathComponent(
        destination.lastPathComponent + ".\(UUID().uuidString).tmp")

    do {
        try data.write(to: temp)
        let handle = try FileHandle(forWritingTo: temp)
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    } catch {
        // Best effort, and deliberately not allowed to mask the real error:
        // the caller needs to hear why the save failed, not why the cleanup
        // did.
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}
