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
    /// One directory per process, and a fresh one. `standard()` is called
    /// twice in a self-test run — once by the practice controller, once by the
    /// check itself — so it cannot be wiped on entry: that would delete the
    /// profile between writing it and reading it back. A `static let` is
    /// initialised once and shared by both calls, which gives the same
    /// property without the wipe.
    ///
    /// Named by UUID rather than by process id. Process ids are recycled, so a
    /// later run could land on the directory an interrupted earlier one left
    /// behind and assert against its half-written profile — a test that passes
    /// or fails based on what happened yesterday. The system reclaims
    /// abandoned directories under `$TMPDIR` on its own.
    private static let selfTestDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypeReviewSelfTest-\(UUID().uuidString)", isDirectory: true)

    static func standard() throws -> ProfileFileStore {
        let directory: URL
        if CommandLine.arguments.contains("--selftest") {
            directory = selfTestDirectory
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
        // "Missing" and "unreadable" are different answers, and only one of
        // them is safe to guess. `.absent` means a clean first run, so the
        // controller starts an empty profile and the next completed run saves
        // it — over whatever is actually on disk. `try?` sent a permission
        // error, an I/O failure and a file that is not valid UTF-8 down that
        // same path, so a profile that existed and merely could not be read
        // was quietly replaced by an empty one.
        //
        // Asked before the read rather than inferred from the error: the
        // question is about the file, and `String(contentsOf:)` reports
        // several unrelated failures through codes that would each have to be
        // enumerated correctly for the answer to be right.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        let json: String
        do {
            json = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            // `.corrupt` is what makes the store read-only, which is the whole
            // point: the file stays on disk, untouched and recoverable.
            return .corrupt(reason: "profile could not be read — \(error.localizedDescription)")
        }
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
