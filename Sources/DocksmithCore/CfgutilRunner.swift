import Foundation
import Darwin

public struct CommandResult {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool

    public init(stdout: Data, stderr: Data = Data(), exitCode: Int32 = 0, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public protocol CfgutilRunning {
    func run(_ arguments: [String]) throws -> CommandResult
}

public enum RunnerError: LocalizedError {
    case executableMissing
    case launchFailed
    case unsupportedInvocation

    public var errorDescription: String? {
        switch self {
        case .executableMissing: "cfgutil was not found. Install Apple Configurator or pass --cfgutil PATH."
        case .launchFailed: "Could not launch cfgutil."
        case .unsupportedInvocation: "Only device listing, installed-app inventory, and layout reads are supported."
        }
    }
}

private final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public final class ProcessCfgutilRunner: CfgutilRunning {
    public let executableURL: URL
    public let timeout: TimeInterval

    public init(path: String? = nil, timeout: TimeInterval = 30) throws {
        guard let resolved = Self.resolve(path: path) else { throw RunnerError.executableMissing }
        executableURL = resolved
        self.timeout = timeout
    }

    private static func resolve(path: String?) -> URL? {
        let candidates: [String]
        if let path { candidates = [path] }
        else {
            let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/cfgutil" }
            candidates = fromPath + ["/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"]
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    public func run(_ arguments: [String]) throws -> CommandResult {
        let isList = arguments == ["--format", "JSON", "list"]
        let isDeviceRead = (arguments.count == 5 || arguments.count == 6)
            && Array(arguments.prefix(3)) == ["--format", "JSON", "--ecid"]
            && !arguments[3].isEmpty
            && ((arguments.count == 6 && Array(arguments.suffix(2)) == ["get", "installedApps"])
                || (arguments.count == 5 && arguments[4] == "get-icon-layout"))
        guard isList || isDeviceRead else { throw RunnerError.unsupportedInvocation }
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { throw RunnerError.launchFailed }

        // Drain both pipes while cfgutil runs so a full pipe cannot stall the child.
        let group = DispatchGroup()
        let stdout = CapturedData()
        let stderr = CapturedData()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.store(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.store(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let timedOut = completed.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
        }
        group.wait()
        return CommandResult(stdout: stdout.load(), stderr: stderr.load(),
                             exitCode: process.terminationStatus, timedOut: timedOut)
    }
}
