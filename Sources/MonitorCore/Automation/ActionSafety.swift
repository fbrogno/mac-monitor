import Darwin
import Foundation

/// Which addresses an `openURL` action may open: web pages and the URL schemes apps register for
/// themselves (`slack://`, `things:///`), never local files, scripts or remote-login schemes.
public enum ActionURLPolicy {
    static let blockedSchemes: Set<String> = [
        "file", "javascript", "data", "vbscript", "about", "blob", "ftp", "ftps", "sftp", "smb", "afp", "nfs",
        "vnc", "ssh", "telnet", "ws", "wss",
    ]

    /// The URL if the text may be opened.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              scheme.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0) }),
              !blockedSchemes.contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
        } else if trimmed.count <= scheme.count + 1 {
            return nil
        }
        return url
    }

    public static func isAllowed(_ text: String) -> Bool { url(from: text) != nil }

    public static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
}

/// Decides, right before a signal is sent, whether a process is still the one the rule meant.
/// PIDs are reused by the system, so a PID alone is not an identity.
public enum SignalGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case gone
        /// The PID now belongs to a process with another name.
        case pidReused(nowNamed: String)
        case protected
    }

    /// `currentName` is the name of whatever runs under `pid` now (nil if nothing does).
    public static func verdict(pid: Int32, expectedName: String, currentName: String?,
                               ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Verdict {
        if pid < ProtectedProcesses.systemPidLimit || pid == ownPid { return .protected }
        guard let currentName, !currentName.isEmpty else { return .gone }
        guard sameName(expectedName, currentName) else { return .pidReused(nowNamed: currentName) }
        if ProtectedProcesses.isProtected(name: currentName) || ProtectedProcesses.isProtected(name: expectedName) {
            return .protected
        }
        return .allowed
    }

    /// Equal without regard to case; one name may be a cut-off form of the other (the kernel shortens long names).
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count >= 15 && long.hasPrefix(short)
    }
}

/// Ends or throttles processes on behalf of a rule. Every PID is checked with `SignalGuard` first.
public enum ProcessControl {
    public enum Outcome: Equatable, Sendable {
        case done
        case skipped(SignalGuard.Verdict)
        case failed(errno: Int32)
    }

    public struct Result: Equatable, Sendable {
        public let process: ProcessRef
        public let outcome: Outcome
    }

    /// The name the system reports for a running PID, nil if there is none.
    public static func currentName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Sends SIGTERM to each target in the given order (main process first).
    public static func terminate(_ targets: [ProcessRef], ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                 currentName: (Int32) -> String? = ProcessControl.currentName(of:)) -> [Result] {
        targets.map { apply($0, ownPid: ownPid, currentName: currentName) { kill($0, SIGTERM) == 0 ? 0 : errno } }
    }

    /// Lowers the priority ("nice" 10) and, where the system allows it, moves the process to background
    /// priority. Nothing is undone automatically.
    public static func throttle(_ targets: [ProcessRef], ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                currentName: (Int32) -> String? = ProcessControl.currentName(of:)) -> [Result] {
        targets.map {
            apply($0, ownPid: ownPid, currentName: currentName) { pid in
                guard setpriority(PRIO_PROCESS, id_t(pid), 10) == 0 else { return errno }
                _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
                return 0
            }
        }
    }

    private static func apply(_ ref: ProcessRef, ownPid: Int32, currentName: (Int32) -> String?,
                              _ act: (Int32) -> Int32) -> Result {
        let verdict = SignalGuard.verdict(pid: ref.pid, expectedName: ref.name, currentName: currentName(ref.pid), ownPid: ownPid)
        guard verdict == .allowed else { return Result(process: ref, outcome: .skipped(verdict)) }
        let code = act(ref.pid)
        if code == 0 { return Result(process: ref, outcome: .done) }
        return Result(process: ref, outcome: code == ESRCH ? .skipped(.gone) : .failed(errno: code))
    }
}

/// Runs and lists Shortcuts through the `shortcuts` command-line tool: a plain process without a shell,
/// so the name is one argument and never interpreted.
public enum ShortcutRunner {
    public enum Result: Equatable, Sendable {
        case success
        case failed(String)
        case timedOut
        case unavailable
        case invalidName
    }

    public static let defaultExecutable = "/usr/bin/shortcuts"

    /// `arguments` and `executable` exist for tests.
    public static func run(name: String, timeout: TimeInterval = 60, executable: String = defaultExecutable,
                           arguments: (String) -> [String] = { ["run", $0] }) async -> Result {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dash would be read as an option by the tool.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.contains("\0") else { return .invalidName }
        let done = await execute(executable: executable, arguments: arguments(trimmed), timeout: timeout)
        switch done.kind {
        case .launchFailed: return .unavailable
        case .timedOut: return .timedOut
        case .exited(let status):
            if status == 0 { return .success }
            let text = done.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? "Beendet mit Code \(status)." : text)
        }
    }

    /// Names of the user's shortcuts; nil if the tool is not available or fails.
    public static func list(timeout: TimeInterval = 15, executable: String = defaultExecutable) async -> [String]? {
        let done = await execute(executable: executable, arguments: ["list"], timeout: timeout, captureOutput: true)
        guard case .exited(0) = done.kind else { return nil }
        return done.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
    }

    private struct Finished {
        enum Kind { case launchFailed, timedOut, exited(Int32) }
        let kind: Kind
        var error = ""
        var output = ""
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var errorData = Data()
        private var outputData = Data()
        private var timedOut = false
        func appendError(_ d: Data) { lock.lock(); if errorData.count < 4096 { errorData.append(d) }; lock.unlock() }
        func appendOutput(_ d: Data) { lock.lock(); if outputData.count < 1_000_000 { outputData.append(d) }; lock.unlock() }
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        var snapshot: (error: String, output: String, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: errorData, as: UTF8.self), String(decoding: outputData, as: UTF8.self), timedOut)
        }
    }

    private static func execute(executable: String, arguments: [String], timeout: TimeInterval,
                                captureOutput: Bool = false) async -> Finished {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let errorPipe = Pipe(), outputPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = captureOutput ? outputPipe : FileHandle.nullDevice
            let collector = Collector()
            errorPipe.fileHandleForReading.readabilityHandler = { collector.appendError($0.availableData) }
            if captureOutput { outputPipe.fileHandleForReading.readabilityHandler = { collector.appendOutput($0.availableData) } }
            process.terminationHandler = { finished in
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputPipe.fileHandleForReading.readabilityHandler = nil
                // What is still in the pipes after the process ended.
                collector.appendError((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
                if captureOutput { collector.appendOutput((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()) }
                let snap = collector.snapshot
                continuation.resume(returning: Finished(
                    kind: snap.timedOut ? .timedOut : .exited(finished.terminationStatus), error: snap.error, output: snap.output))
            }
            do { try process.run() } catch {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: Finished(kind: .launchFailed))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                process.terminate()
            }
        }
    }
}
