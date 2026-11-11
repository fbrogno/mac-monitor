import Foundation
import Testing
@testable import MonitorCore

/// All tests work on temporary directories; nothing outside them is ever touched.
@Suite struct CleanupSafetyTests {
    private let fm = FileManager.default

    /// A scratch area with a fake home folder and a separate folder that must never be touched.
    private struct Sandbox {
        let root: URL
        let home: String
        let outside: String

        var caches: String { home + "/Library/Caches" }
    }

    private func sandbox() throws -> Sandbox {
        // /var is a link to /private/var: use the resolved path so `home` and its real path agree like on a real Mac.
        let temp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        let base = URL(fileURLWithPath: temp).appendingPathComponent("mm-cleanup-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "wichtig".write(to: outside.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: outside.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try "wichtig".write(to: outside.appendingPathComponent("Caches/important.txt"), atomically: true, encoding: .utf8)
        return Sandbox(root: base, home: home.path, outside: outside.path)
    }

    private func write(_ path: String, _ text: String = "x") throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }

    private func intact(_ s: Sandbox) -> Bool {
        (try? String(contentsOfFile: s.outside + "/important.txt", encoding: .utf8)) == "wichtig"
            && (try? String(contentsOfFile: s.outside + "/Caches/important.txt", encoding: .utf8)) == "wichtig"
    }

    @Test func emptiesTheFolderAndKeepsTheFolderItselfAndKeptEntries() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        try write(s.caches + "/a.bin")
        try write(s.caches + "/com.app/sub/b.bin")
        try write(s.caches + "/ms-playwright-1234/browser")
        let report = CleanupSafety.empty(folder: s.caches, home: s.home, keeping: ["ms-playwright"])
        #expect(report.refusal == nil)
        #expect(report.removed == 2 && report.keptOnPurpose == 1 && report.skipped == 0)
        #expect(!exists(s.caches + "/a.bin") && !exists(s.caches + "/com.app"))
        #expect(exists(s.caches + "/ms-playwright-1234/browser"))
        #expect(exists(s.caches))
    }

    @Test func symlinkInsideIsRemovedAsLinkAndItsTargetSurvives() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        // A link to a folder outside, and a real sub folder that itself contains such a link.
        try fm.createSymbolicLink(atPath: s.caches + "/link-to-outside", withDestinationPath: s.outside)
        try write(s.caches + "/nested/file")
        try fm.createSymbolicLink(atPath: s.caches + "/nested/inner-link", withDestinationPath: s.outside + "/Caches")
        try fm.createSymbolicLink(atPath: s.caches + "/dangling", withDestinationPath: "/gibt/es/nicht")
        let report = CleanupSafety.empty(folder: s.caches, home: s.home)
        #expect(report.refusal == nil)
        #expect(report.removed == 3)
        #expect(try fm.contentsOfDirectory(atPath: s.caches).isEmpty)
        #expect(intact(s), "the content behind the links must still be there")
    }

    @Test func aFolderThatIsASymlinkIsRefusedAndNothingBehindItIsTouched() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        try fm.removeItem(atPath: s.caches)
        try fm.createSymbolicLink(atPath: s.caches, withDestinationPath: s.outside + "/Caches")
        let report = CleanupSafety.empty(folder: s.caches, home: s.home)
        #expect(report.refusal == .isSymlink)
        #expect(report.removed == 0)
        #expect(intact(s))
    }

    @Test func aLinkedParentFolderIsRefused() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        // ~/Library points to a folder elsewhere: ~/Library/Caches is a real folder, but not below the real home.
        try fm.removeItem(atPath: s.home + "/Library")
        try fm.createSymbolicLink(atPath: s.home + "/Library", withDestinationPath: s.outside)
        let report = CleanupSafety.empty(folder: s.caches, home: s.home)
        #expect(report.refusal == .outsideHome)
        #expect(report.removed == 0)
        #expect(intact(s))
    }

    @Test func anUnusableHomeNeverEmptiesAnything() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        // Empty home would turn "~/Library/Caches" into "/Library/Caches"; "/" likewise.
        for home in ["", "/", "relative/home", "/gibt/es/nicht", s.home + "/../home", s.outside + "/important.txt"] {
            for folder in ["/Library/Caches", home + "/Library/Caches", s.caches] {
                let report = CleanupSafety.empty(folder: folder, home: home)
                #expect(report.refusal != nil, "home \"\(home)\", folder \(folder)")
                #expect(report.removed == 0)
            }
        }
        #expect(CleanupSafety.realHome("") == nil && CleanupSafety.realHome("/") == nil)
        #expect(CleanupSafety.realHome(s.home) == s.home)
    }

    @Test func onlyTheFixedFoldersBelowHomeAreAllowed() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        for relative in ["Documents", "Desktop", "Library", "Library/Application Support", "Library/Caches/../Documents", ".ssh", ""] {
            try fm.createDirectory(atPath: s.home + "/" + relative, withIntermediateDirectories: true)
            try write(s.home + "/" + relative + "/keep.txt")
            let report = CleanupSafety.empty(folder: relative.isEmpty ? s.home : s.home + "/" + relative, home: s.home)
            #expect(report.refusal == .notAllowed, "\(relative)")
            #expect(exists(s.home + "/" + relative + "/keep.txt"))
        }
        // A folder outside home, and one that only starts with the same text.
        #expect(CleanupSafety.empty(folder: s.outside + "/Caches", home: s.home).refusal == .notAllowed)
        #expect(CleanupSafety.empty(folder: s.home + "-evil/Library/Caches", home: s.home).refusal == .notAllowed)
        #expect(intact(s))
    }

    @Test func allowedFoldersThatDoNotExistAreSimplySkipped() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        #expect(CleanupSafety.empty(folder: s.home + "/.npm/_cacache", home: s.home).refusal == .missing)
        // A file where a folder is expected.
        try write(s.home + "/.gradle/caches", "datei")
        #expect(CleanupSafety.empty(folder: s.home + "/.gradle/caches", home: s.home).refusal == .notADirectory)
        #expect(exists(s.home + "/.gradle/caches"))
    }

    @Test func entryDecisions() throws {
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        try write(s.caches + "/file")
        try fm.createSymbolicLink(atPath: s.caches + "/link", withDestinationPath: s.outside)
        var info = stat()
        lstat(s.caches, &info)
        func action(_ name: String, keeping: [String] = []) -> CleanupSafety.EntryAction {
            CleanupSafety.action(forEntry: name, in: s.caches, keeping: keeping, folderDevice: info.st_dev)
        }
        #expect(action("file") == .remove)
        #expect(action("link") == .unlink)
        #expect(action("file", keeping: ["fi"]) == .keep)
        #expect(action("gone") == .skip)
        #expect(["", ".", "..", "a/b", "../x"].allSatisfy { action($0) == .skip })
        // A folder on another volume would be left alone: a different device number says so.
        try fm.createDirectory(atPath: s.caches + "/dir", withIntermediateDirectories: true)
        #expect(CleanupSafety.action(forEntry: "dir", in: s.caches, keeping: [], folderDevice: info.st_dev) == .remove)
        #expect(CleanupSafety.action(forEntry: "dir", in: s.caches, keeping: [], folderDevice: info.st_dev &+ 1) == .skip)
    }

    @Test func everyAllowedFolderIsReallyEmptiedBelowAHome() throws {
        // The folders the app cleans (see CleanupTarget) must all pass the rules, or cleaning would silently do nothing.
        let s = try sandbox()
        defer { try? fm.removeItem(at: s.root) }
        for relative in CleanupSafety.allowedFolders {
            try write(s.home + "/" + relative + "/entry")
            let report = CleanupSafety.empty(folder: s.home + "/" + relative, home: s.home)
            #expect(report.refusal == nil && report.removed == 1, "\(relative)")
        }
        #expect(CleanupSafety.allowedFolders.count == 5)
    }
}
