import Foundation
import TypeReviewKit

/// The profile as a file the user owns.
///
/// The whole reason this is a native app rather than a web page: in a browser
/// the profile lives in evictable storage, and "your typing history may be
/// deleted to reclaim space" is not a sentence a practice log should have to
/// contain. A file in Application Support is subject to none of that.
struct ProfileFileStore {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("profile.json") }

    /// Where the app keeps the profile — and, under `--selftest`, where it
    /// does not.
    ///
    /// The self-test finishes a whole run and asserts it reached disk, which
    /// is the only check covering the write path end to end. Pointed at the
    /// real profile, that assertion cost something: every `make selftest`
    /// appended a fabricated 100-wpm run to the user's history, which moves
    /// their statistics, their per-key timings and the alphabet the next
    /// lesson unlocks. A check that damages what it is checking is not a
    /// check, so the self-test gets a profile of its own.
    ///
    /// One redirect covers both files: `LibraryStore.standard()` takes this
    /// directory, so the library round-trip stops writing a passage called
    /// "selftest" into the user's own text as well.
    ///
    /// Keyed by process id rather than wiped on entry. `standard()` is called
    /// twice in a self-test run — once by the practice controller, once by the
    /// check itself — and a directory that resets on each call would delete
    /// the profile between writing it and reading it back.
    static func standard() throws -> ProfileFileStore {
        let directory: URL
        if CommandLine.arguments.contains("--selftest") {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TypeReviewSelfTest-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
            let bundleID = Bundle.main.bundleIdentifier ?? "review.type.app"
            directory = base.appendingPathComponent(bundleID, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProfileFileStore(directory: directory)
    }

    func load() -> LoadResult {
        guard let json = try? String(contentsOf: fileURL, encoding: .utf8) else { return .absent }
        // Straight through the ported validator: a file edited by hand, or
        // half-written by a crash, is caught here rather than becoming
        // impossible statistics later.
        return deserializeProfile(json)
    }

    /// Atomic *and* durable — see `writeDurably`, which both stores share.
    func save(_ profile: Profile) throws {
        try writeDurably(
            Data(serializeProfileString(profile).utf8), to: fileURL, in: directory)
    }
}
