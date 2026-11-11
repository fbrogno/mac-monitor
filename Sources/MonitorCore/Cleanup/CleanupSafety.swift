import Darwin
import Foundation

/// The rules for emptying cache folders, kept free of the UI so they can be tested on temporary directories.
///
/// Deleting is the most dangerous thing the app does, so it is deliberately narrow:
/// - the home folder must be a real, absolute folder owned by the user, never `/` and never empty (an empty home
///   would turn `~/Library/Caches` into `/Library/Caches`);
/// - only folders from a fixed list below the home folder are emptied (`allowedFolders`);
/// - the folder itself must not be a symbolic link, and its resolved path must be exactly the expected one below
///   the resolved home (so a linked `~/Library` is refused as well);
/// - inside, symbolic links are removed as links and never followed, and folders on another volume are left alone.
public enum CleanupSafety {
    /// Folders below the home folder that may be emptied, relative to it.
    public static let allowedFolders: [String] = [
        "Library/Caches", "Library/Developer/Xcode/DerivedData", ".npm/_cacache", ".cache/uv", ".gradle/caches",
    ]

    public enum Refusal: Error, Equatable, Sendable {
        /// Empty, relative, `/`, with `..`, not a folder, or not owned by the user.
        case invalidHome
        /// Not below the home folder, or not one of the allowed folders.
        case notAllowed
        case missing
        case isSymlink
        case notADirectory
        /// The resolved path is not the expected one below the resolved home.
        case outsideHome
    }

    public struct Report: Equatable, Sendable {
        public var removed = 0
        public var keptOnPurpose = 0
        /// Entries that were left alone for safety or could not be removed.
        public var skipped = 0
        public var refusal: Refusal?
    }

    /// The resolved path of a usable home folder.
    public static func realHome(_ home: String) -> String? {
        guard !home.isEmpty, home.hasPrefix("/"), !hasDotDot(home) else { return nil }
        guard let real = realPath(home), real != "/" else { return nil }
        var info = stat()
        guard lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return nil }
        return real
    }

    /// The resolved path of `folder` if it may be emptied, otherwise why not. Nothing is changed.
    public static func resolveFolder(_ folder: String, home: String,
                                     allowed: [String] = allowedFolders) -> Result<String, Refusal> {
        guard let realHome = realHome(home) else { return .failure(.invalidHome) }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard folder.hasPrefix(prefix), !hasDotDot(folder) else { return .failure(.notAllowed) }
        var relative = String(folder.dropFirst(prefix.count))
        while relative.hasSuffix("/") { relative.removeLast() }
        guard allowed.contains(relative) else { return .failure(.notAllowed) }

        var info = stat()
        guard lstat(folder, &info) == 0 else { return .failure(.missing) }
        if info.st_mode & S_IFMT == S_IFLNK { return .failure(.isSymlink) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(.notADirectory) }
        guard let real = realPath(folder), real == realHome + "/" + relative else { return .failure(.outsideHome) }
        return .success(real)
    }

    /// What happens to one entry of an emptied folder.
    public enum EntryAction: Equatable, Sendable {
        /// A symbolic link: the link is removed, what it points to is not touched.
        case unlink
        /// A file or a folder on the same volume: removed (folders with everything inside, links inside not followed).
        case remove
        case keep
        case skip
    }

    /// Decision for one entry (`name` is a plain name, `folderDevice` the volume of the emptied folder).
    public static func action(forEntry name: String, in folder: String, keeping: [String], folderDevice: dev_t) -> EntryAction {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return .skip }
        if keeping.contains(where: name.hasPrefix) { return .keep }
        var info = stat()
        guard lstat(folder + "/" + name, &info) == 0 else { return .skip }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .unlink
        case S_IFDIR: return info.st_dev == folderDevice ? .remove : .skip   // another volume mounted inside
        default: return .remove
        }
    }

    /// Empties `folder` if the rules allow it; entries starting with one of `keeping` stay.
    @discardableResult
    public static func empty(folder: String, home: String, keeping: [String] = [],
                             allowed: [String] = allowedFolders) -> Report {
        var report = Report()
        let real: String
        switch resolveFolder(folder, home: home, allowed: allowed) {
        case .failure(let refusal):
            report.refusal = refusal
            return report
        case .success(let path):
            real = path
        }
        var info = stat()
        guard lstat(real, &info) == 0, let names = try? FileManager.default.contentsOfDirectory(atPath: real) else {
            report.refusal = .missing
            return report
        }
        for name in names {
            let path = real + "/" + name
            switch action(forEntry: name, in: real, keeping: keeping, folderDevice: info.st_dev) {
            case .keep:
                report.keptOnPurpose += 1
            case .skip:
                report.skipped += 1
            case .unlink:
                if unlink(path) == 0 { report.removed += 1 } else { report.skipped += 1 }
            case .remove:
                do { try FileManager.default.removeItem(atPath: path); report.removed += 1 } catch { report.skipped += 1 }
            }
        }
        return report
    }

    private static func hasDotDot(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
