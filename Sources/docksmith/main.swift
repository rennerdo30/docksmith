import Foundation
import DocksmithCore

private let usage = """
Docksmith: inspect connected Apple devices without changing them.

Usage:
  docksmith devices [--cfgutil PATH]
  docksmith probe (--device NUMBER | --ecid VALUE) [--cfgutil PATH]
  docksmith help

`devices` lists transient numbers for currently connected devices. `probe`
discovers again before reading; reconnecting devices can change the numbers.
Reports omit identifiers, app records, and layout contents.
"""

@main
struct CLI {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("docksmith: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ args: [String]) throws {
        if args.isEmpty || args[0] == "help" || args[0] == "--help" {
            print(usage)
            return
        }
        guard args[0] == "devices" || args[0] == "probe" else {
            throw CLIError.invalidArguments
        }
        var cfgutilPath: String?
        var ordinal: Int?
        var selectedECID: String?
        var index = 1
        while index < args.count {
            guard index + 1 < args.count else { throw CLIError.invalidArguments }
            let flag = args[index]
            let value = args[index + 1]
            switch flag {
            case "--cfgutil": cfgutilPath = value
            case "--device": ordinal = Int(value)
            case "--ecid": selectedECID = value
            default: throw CLIError.invalidArguments
            }
            index += 2
        }
        let runner = try ProcessCfgutilRunner(path: cfgutilPath)
        let probe = DocksmithProbe(runner: runner)
        if args[0] == "devices" {
            guard ordinal == nil, selectedECID == nil else { throw CLIError.invalidArguments }
            let discovery = try probe.discover()
            print("Connected devices: \(discovery.devices.count)")
            for (index, device) in discovery.devices.enumerated() {
                print("  \(index + 1). \(device.category)")
            }
            if let warning = discovery.warning { print("Warning: \(warning)") }
            return
        }
        guard (ordinal == nil) != (selectedECID == nil) else { throw ProbeError.selectionRequired }
        let selection: String
        if let selectedECID { selection = selectedECID }
        else {
            let discovery = try probe.discover()
            guard let ordinal, ordinal > 0, ordinal <= discovery.devices.count else { throw ProbeError.deviceNotFound }
            selection = discovery.devices[ordinal - 1].ecid
        }
        let report = try probe.probe(ecid: selection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

private enum CLIError: LocalizedError {
    case invalidArguments
    var errorDescription: String? { "Invalid arguments. Run `docksmith help` for usage." }
}
