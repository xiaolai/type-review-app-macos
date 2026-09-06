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

    static func standard() throws -> ProfileFileStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "review.type.app"
        let directory = base.appendingPathComponent(bundleID, isDirectory: true)
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
