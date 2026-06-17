//
//  dump.swift  — BtnQ DDC dump CLI
//
//  A one-shot command-line dump of every candidate VCP code's current value,
//  decoded against a monitor config. Built from the same vendored DDC code and
//  MonitorConfig the app uses, so labels / channels / recognised values match.
//
//  Run via Tools/dump.sh (compiles this with the app's DDC sources).
//

import CoreGraphics
import Foundation

@main
enum DumpTool {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let configPath = args.first(where: { $0.hasSuffix(".json") })
            ?? "\(FileManager.default.currentDirectoryPath)/BtnQ/Monitors/BenQ-RD280UG.json"

        let config = (try? Data(contentsOf: URL(fileURLWithPath: configPath)))
            .flatMap { try? JSONDecoder().decode(MonitorConfig.self, from: $0) }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        let matches = AppleSiliconDDC.getServiceMatches(displayIDs: Array(ids.prefix(Int(n))))

        let match = matches.first { m in
            guard m.service != nil else { return false }
            let name = m.serviceDetails.productName
            if let config { return config.matches(productName: name, vendor: nil, product: nil) }
            return name.range(of: "RD280", options: .caseInsensitive) != nil
        }
        guard let match, let service = match.service else {
            err("No matching BenQ display found.")
            exit(1)
        }

        var codeMap: [UInt8: [Control]] = [:]
        for control in config?.controls ?? [] {
            if let code = control.featureCode { codeMap[code, default: []].append(control) }
        }

        print("display : \(match.serviceDetails.productName)")
        print("config  : \(config?.name ?? "(none)")  [\(configPath)]")
        if let caps = AppleSiliconDDC.readCapabilities(service: service) {
            print("caps    : \(caps)")
            let parsed = AppleSiliconDDC.parseVCPCodes(from: caps)
            let valueLists = parsed
                .filter { !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { code, values in
                    let list = values.map { String(format: "%02X", $0) }.joined(separator: " ")
                    return String(format: "%02X(%@)", code, list)
                }
                .joined(separator: " ")
            if !valueLists.isEmpty { print("values  : \(valueLists)") }
        }
        print(String(format: "%-4@ %6@  %-8@ %@", "VCP", "dec", "hex", "meaning"))
        print(String(repeating: "─", count: 56))

        let codes = (DDCProbe.scanCodes + codeMap.keys).reduce(into: [UInt8]()) { out, code in
            if !out.contains(code) { out.append(code) }
        }

        for code in codes {
            // Two agreeing reads reject transient bus garbage so diffs are clean.
            guard let a = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 2),
                  let b = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 2),
                  a.current == b.current else {
                print(String(format: "%02X   %6@  %-8@ (unstable)", code, "—", "—"))
                continue
            }
            let v = Int(a.current)
            let meaning = describe(codeMap[code] ?? [], v)
            print(String(format: "%02X   %6d  0x%-6X %@", code, v, v, meaning))
        }
    }

    /// Decode a value the way the app's listener does: multiplexed registers
    /// (high byte = channel) get channel:value, simple controls get the
    /// recognised meaning.
    static func describe(_ controls: [Control], _ raw: Int) -> String {
        guard !controls.isEmpty else { return "" }
        let packed = controls.filter { $0.byte != nil }
        if !packed.isEmpty {
            let parts = packed.compactMap { c in c.label.map { "\($0)=\(c.byteValue(raw))" } }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        if controls.contains(where: { $0.channelByte != nil }) {
            let channel = UInt8((raw >> 8) & 0xFF)
            let value = raw & 0xFF
            if let label = controls.first(where: { $0.channelByte == channel })?.label {
                return "\(label)=\(value)"
            }
            return String(format: "ch 0x%02X=%d", channel, value)
        }
        let masked = controls.filter { $0.valueMask != nil }
        if !masked.isEmpty {
            let parts = masked.compactMap { control -> String? in
                guard let name = control.label, let value = control.recognise(raw) else { return nil }
                return "\(name)=\(value)"
            }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        let name = controls.first?.label ?? ""
        for control in controls where control.recognise(raw) != nil {
            return "\(name): \(control.recognise(raw)!)"
        }
        return "\(name): unrecognised"
    }

    static func err(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
