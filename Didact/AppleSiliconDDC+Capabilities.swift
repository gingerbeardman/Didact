//
//  AppleSiliconDDC+Capabilities.swift
//  BtnQ
//
//  DDC/CI Capabilities Request (op 0xF3 / reply 0xE3): ask the monitor for its
//  capabilities string, which lists every VCP feature it supports. The string
//  comes back in fragments — each request returns the bytes at a given offset,
//  so we loop, bumping the offset, until an empty fragment marks the end.
//
//  Kept out of the vendored AppleSiliconDDC.swift so that file stays a clean
//  mirror of upstream; an extension in the same module can still reach its
//  internal helpers (checksum, the address constants, the I2C bridge calls).
//

import Foundation
import IOKit

extension AppleSiliconDDC {
    /// Read and assemble the monitor's full DDC/CI capabilities string, or nil if
    /// the monitor doesn't answer (some don't). Bounded so a misbehaving monitor
    /// that never returns an empty fragment can't loop forever.
    static public func readCapabilities(service: IOAVService?, maxLength: Int = 4096) -> String? {
        guard service != nil else { return nil }
        var bytes: [UInt8] = []
        var offset = 0
        while offset < maxLength {
            guard let fragment = capabilitiesFragment(service: service, offset: UInt16(offset)) else { break }
            if fragment.isEmpty { break }   // empty fragment → end of string
            bytes.append(contentsOf: fragment)
            offset += fragment.count
        }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Request one fragment of the capabilities string at `offset` and return its
    /// data bytes (empty array = monitor reported no more data), or nil on failure.
    private static func capabilitiesFragment(service: IOAVService?, offset: UInt16,
                                             numOfRetryAttempts: Int = 4) -> [UInt8]? {
        let dataAddress = ARM64_DDC_DATA_ADDRESS
        // DDC/CI capabilities request: op 0xF3 + a 2-byte offset, length 3 →
        // [0x80|3, 0xF3, offHi, offLo, checksum]. Built directly rather than via
        // the vendored read/write shorthand, which encodes the op code AS the
        // payload length (valid only for GET=0x01 and SET=0x03); reusing it here
        // emitted a malformed SET, which the monitor silently ignored.
        let body: [UInt8] = [0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        var packet: [UInt8] = [UInt8(0x80 | body.count)] + body + [0]
        packet[packet.count - 1] = checksum(
            chk: ARM64_DDC_7BIT_ADDRESS << 1 ^ dataAddress, data: &packet, start: 0, end: packet.count - 2)

        for _ in 0 ... numOfRetryAttempts {
            var reply = [UInt8](repeating: 0, count: 64)  // src + len + op + 2 offset + ≤32 data + checksum
            // Two write cycles like the normal read path, in case the bus needs waking.
            usleep(10000)
            _ = IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &packet, UInt32(packet.count))
            usleep(10000)
            _ = IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &packet, UInt32(packet.count))
            usleep(50000)
            if IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &reply, UInt32(reply.count)) == 0,
               let fragment = parseCapabilitiesReply(reply, requestedOffset: offset) {
                return fragment
            }
            usleep(20000)
        }
        return nil
    }

    /// Validate and extract the data bytes from a 0xE3 capabilities reply.
    /// Framing: [0]=source addr, [1]=0x80|bodyLen, [2]=0xE3, [3..4]=offset,
    /// [5..]=data, then the checksum byte.
    private static func parseCapabilitiesReply(_ reply: [UInt8], requestedOffset: UInt16) -> [UInt8]? {
        guard reply.count >= 6, (reply[1] & 0x80) != 0 else { return nil }
        let bodyLen = Int(reply[1] & 0x7F)            // op + 2 offset bytes + data
        let checksumIndex = 2 + bodyLen
        guard bodyLen >= 3, reply.count > checksumIndex else { return nil }
        guard reply[2] == 0xE3 else { return nil }

        // DDC/CI reply checksum: 0x50 XOR every byte up to (not including) the checksum.
        var chk: UInt8 = 0x50
        for i in 0 ..< checksumIndex { chk ^= reply[i] }
        guard chk == reply[checksumIndex] else { return nil }

        let echoedOffset = UInt16(reply[3]) << 8 | UInt16(reply[4])
        guard echoedOffset == requestedOffset else { return nil }

        return Array(reply[5 ..< checksumIndex])      // the data bytes (may be empty)
    }

    /// Parse the `vcp(...)` section of a capabilities string into a map of
    /// feature code → allowed values. An empty value array means a continuous
    /// (range) feature; a non-empty one lists a cycle/toggle's legal values.
    /// Returns an empty map when there's no parseable `vcp(...)` section.
    static func parseVCPCodes(from capabilities: String) -> [UInt8: [Int]] {
        guard let open = capabilities.range(of: "vcp(", options: .caseInsensitive) else { return [:] }
        var depth = 1
        var idx = open.upperBound
        let start = idx
        var end = capabilities.endIndex
        while idx < capabilities.endIndex {
            let c = capabilities[idx]
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1; if depth == 0 { end = idx; break } }
            idx = capabilities.index(after: idx)
        }
        return parseVCPBody(String(capabilities[start ..< end]))
    }

    /// Body of a `vcp(...)` section, e.g. "10 12 60 (0F 11 13) D7". A token's role
    /// is decided purely by parenthesis depth: hex tokens at depth 0 are feature
    /// codes; tokens inside `(…)` are that code's allowed values. Tracking depth
    /// this way means a value (e.g. the `0A` in `68 (… 0A …)`) can never be
    /// mistaken for a top-level code.
    private static func parseVCPBody(_ body: String) -> [UInt8: [Int]] {
        var result: [UInt8: [Int]] = [:]
        var depth = 0
        var lastCode: UInt8?
        var token = ""

        func flush(_ atDepth: Int) {
            defer { token = "" }
            guard let value = Int(token, radix: 16) else { return }
            if atDepth == 0 {
                if value <= 0xFF { result[UInt8(value)] = result[UInt8(value)] ?? []; lastCode = UInt8(value) }
            } else if let code = lastCode {
                result[code, default: []].append(value)
            }
        }

        for ch in body {
            if ch.isHexDigit {
                token.append(ch)
            } else if ch == "(" {
                flush(0)                 // the token right before '(' is a code
                depth += 1
            } else if ch == ")" {
                flush(depth)             // the token right before ')' is a value
                depth = max(0, depth - 1)
            } else {                     // whitespace / separator
                flush(depth)
            }
        }
        flush(depth)
        return result
    }
}
