//
//  read-vcp.swift — read one DDC/VCP value from the first matching display.
//

import CoreGraphics
import Foundation

@main
enum ReadVCPTool {
    static func main() {
        let code = parseCode(CommandLine.arguments.dropFirst().first) ?? 0xD7

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)

        let matches = AppleSiliconDDC.getServiceMatches(displayIDs: Array(ids.prefix(Int(count))))
        let match = matches.first { candidate in
            candidate.service != nil &&
            candidate.serviceDetails.productName.range(of: "RD280", options: .caseInsensitive) != nil
        } ?? matches.first { $0.service != nil }

        guard let service = match?.service else {
            err("No DDC-capable display found.")
            exit(1)
        }

        let first = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 2)
        let second = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 2)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        guard let first, let second, first.current == second.current else {
            let a = first.map { String(format: "0x%04X", $0.current) } ?? "nil"
            let b = second.map { String(format: "0x%04X", $0.current) } ?? "nil"
            print(String(format: "%@ VCP %02X unstable %@ %@", timestamp, code, a, b))
            exit(2)
        }

        print(String(format: "%@ VCP %02X %5d 0x%04X", timestamp, code, first.current, first.current))
    }

    private static func parseCode(_ raw: String?) -> UInt8? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard let value = UInt8(cleaned, radix: 16) else { return nil }
        return value
    }

    private static func err(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
