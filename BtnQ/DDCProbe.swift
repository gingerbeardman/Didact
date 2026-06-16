//
//  DDCProbe.swift
//  BtnQ
//
//  Candidate VCP codes to poll in Listen mode, ported from bebenqli's discovery
//  sweep (controls.py / idebug.py). The idea: read every candidate once to form
//  a baseline, then poll repeatedly — whichever code changes when you press a
//  button on the monitor's own OSD is the one that controls that feature.
//

import Foundation

enum DDCProbe {
    /// Codes worth polling: everything the panel's capabilities string reports,
    /// plus the whole 0xD0–0xFF vendor range (BenQ hides extras there). Excluded:
    /// 04/08/0C (restore-defaults / save-settings — never touch) and the known
    /// auto-movers (E1 active-control counter, D7 BI/ambient composite, E3 light
    /// meter) that drift on their own and would spam the log.
    static let scanCodes: [UInt8] = {
        let caps: [UInt8] = [
            0x02, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x52, 0x60, 0x62, 0x72,
            0x86, 0x87, 0x8A, 0x8D, 0xC1, 0xC2, 0xC9, 0xCA, 0xCC, 0xD0, 0xD1,
            0xD2, 0xD7, 0xD9, 0xDC, 0xDF, 0xE1, 0xE2, 0xE3, 0xE5, 0xE6, 0xE7,
            0xE9, 0xEB, 0xEE, 0xEF, 0xF0, 0xF1, 0xF8, 0xFD,
        ]
        let vendorRange: [UInt8] = (0xD0...0xFF).map { UInt8($0) }
        // 04/08/0C: restore/save — never touch. E1/D7/E3: known auto-movers.
        // C9: firmware version (read-only, glitches to 0 during OSD use).
        let skip: Set<UInt8> = [0x04, 0x08, 0x0C, 0xE1, 0xD7, 0xE3, 0xC9]

        var seen = Set<UInt8>()
        var out: [UInt8] = []
        for code in caps + vendorRange where !skip.contains(code) && seen.insert(code).inserted {
            out.append(code)
        }
        return out
    }()

    /// Codes to watch while TEACHING a control. Same set as `scanCodes` but with
    /// the auto-movers (D7 Moon Halo composite, E1, E3) added back: in the wizard
    /// the user is actively driving one control and we require a clear leader, so
    /// their idle drift no longer matters — and D7 is exactly the code Moon Halo
    /// lives on, which `scanCodes` deliberately omits.
    static let learnCodes: [UInt8] = {
        var seen = Set<UInt8>()
        var out: [UInt8] = []
        for code in scanCodes + [0xD7, 0xE1, 0xE3] where seen.insert(code).inserted {
            out.append(code)
        }
        return out
    }()
}
