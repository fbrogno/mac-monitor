import AppKit
import Foundation
import MonitorCore

/// A place on disk that can be emptied without losing user data: it only holds caches and build
/// products that tools recreate on demand.
struct CleanupTarget: Identifiable, Sendable {
    enum Method: Sendable {
        /// Delete everything inside these folders, keeping the folders themselves and any
        /// entry whose name starts with one of `keeping`.
        case emptyFolders([String], keeping: [String] = [])
        /// Run a tool's own cleanup command.
        case command(executable: String, arguments: [[String]])
        /// Not deleted by us; we only open it for the user to decide.
        case revealOnly(String)
    }

    let id: String
    let title: String
    let detail: String
    /// What the confirmation dialog says will happen.
    let consequence: String
    /// Folders whose size is reported.
    let measuredPaths: [String]
    let method: Method

    var isRevealOnly: Bool {
        if case .revealOnly = method { return true }
        return false
    }

    static func all(home: String = NSHomeDirectory()) -> [CleanupTarget] {
        func h(_ path: String) -> String { home + "/" + path }
        var targets: [CleanupTarget] = [
            CleanupTarget(
                id: "caches", title: String(localized: "App-Caches"), detail: "~/Library/Caches",
                consequence: String(localized: "Apps laden Vorschaubilder und Daten beim nächsten Start neu. Offene Apps solltest du danach neu starten."),
                measuredPaths: [h("Library/Caches")],
                // Playwright keeps its browser binaries here and does not re-download them by itself.
                method: .emptyFolders([h("Library/Caches")], keeping: ["ms-playwright"])),
            CleanupTarget(
                id: "derived", title: String(localized: "Xcode DerivedData"), detail: String(localized: "Build-Zwischenstände"),
                consequence: String(localized: "Der nächste Xcode-Build dauert einmal länger."),
                measuredPaths: [h("Library/Developer/Xcode/DerivedData")],
                method: .emptyFolders([h("Library/Developer/Xcode/DerivedData")])),
            CleanupTarget(
                id: "npm", title: String(localized: "npm-Cache"), detail: "~/.npm",
                consequence: String(localized: "Pakete werden bei der nächsten Installation neu geladen."),
                measuredPaths: [h(".npm")], method: .emptyFolders([h(".npm/_cacache")])),
            // Only uv: other folders in ~/.cache hold indexes and data that are not caches
            // in the throw-away sense (e.g. qmd search indexes).
            CleanupTarget(
                id: "uv", title: String(localized: "uv-Cache (Python)"), detail: "~/.cache/uv",
                consequence: String(localized: "Python-Pakete werden bei der nächsten Installation neu geladen."),
                measuredPaths: [h(".cache/uv")], method: .emptyFolders([h(".cache/uv")])),
            CleanupTarget(
                id: "gradle", title: String(localized: "Gradle-Cache"), detail: "~/.gradle/caches",
                consequence: String(localized: "Der nächste Gradle-Build lädt Abhängigkeiten neu."),
                measuredPaths: [h(".gradle/caches")], method: .emptyFolders([h(".gradle/caches")])),
        ]
        if let xcrun = ["/usr/bin/xcrun"].first(where: FileManager.default.isExecutableFile(atPath:)) {
            targets.append(CleanupTarget(
                id: "simulators", title: String(localized: "Veraltete Simulatoren"), detail: String(localized: "iOS-Simulatoren nicht mehr installierter Versionen"),
                consequence: String(localized: "Entfernt nur Simulatoren, deren iOS-Version nicht mehr installiert ist."),
                measuredPaths: [h("Library/Developer/CoreSimulator")],
                method: .command(executable: xcrun, arguments: [["simctl", "delete", "unavailable"]])))
        }
        if let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first(where: FileManager.default.isExecutableFile(atPath:)) {
            targets.append(CleanupTarget(
                id: "docker", title: String(localized: "Docker: ungenutzte Images & Build-Cache"), detail: String(localized: "Container und Volumes bleiben erhalten"),
                consequence: String(localized: "Entfernt Images ohne Container und den Build-Cache. Laufende und gestoppte Container sowie Volumes bleiben."),
                measuredPaths: [h("Library/Containers/com.docker.docker")],
                method: .command(executable: docker, arguments: [["image", "prune", "-a", "-f"], ["builder", "prune", "-f"]])))
        }
        targets.append(CleanupTarget(
            id: "downloads", title: String(localized: "Downloads"), detail: String(localized: "Deine Dateien – nur du entscheidest"),
            consequence: "", measuredPaths: [h("Downloads")], method: .revealOnly(h("Downloads"))))
        return targets
    }
}

enum CleanupRunner {
    /// Allocated size of all files below `path`, following no symlinks.
    static func size(of path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func size(of target: CleanupTarget) -> UInt64 {
        target.measuredPaths.reduce(0) { $0 + size(of: $1) }
    }

    /// Performs the cleanup. Items that cannot be removed (in use, protected) are skipped.
    static func run(_ target: CleanupTarget) {
        switch target.method {
        case .emptyFolders(let folders, let keeping):
            // The rules (fixed folder list below the home folder, no symlinks followed) live in `CleanupSafety`.
            for folder in folders {
                CleanupSafety.empty(folder: folder, home: NSHomeDirectory(), keeping: keeping)
            }
        case .command(let executable, let argumentSets):
            for arguments in argumentSets {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        case .revealOnly:
            break
        }
    }
}
