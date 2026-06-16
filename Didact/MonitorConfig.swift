//
//  MonitorConfig.swift
//  BtnQ
//
//  The monitor "spec" is pure data, loaded from JSON so the community can add
//  support for new monitors without writing any code. Files are loaded from the
//  app bundle and from ~/Library/Application Support/Didact/Monitors/.
//

import Foundation

/// A value that decodes from either a JSON number (decimal) or a string
/// (hexadecimal, with optional "0x"/"#" prefix). DDC docs are written in hex, so
/// authors can mirror them directly — `"0x30"` — while still allowing `255`.
struct HexValue: Codable, Equatable {
    let value: Int

    init(_ value: Int) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            value = i
            return
        }
        let s = try c.decode(String.self)
        let cleaned = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "#", with: "")
        guard let v = Int(cleaned, radix: 16) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Not a valid hex/decimal value: \"\(s)\"")
        }
        value = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

struct MonitorConfig: Codable, Identifiable {
    var id: String { name }
    let name: String
    /// Substrings matched (case-insensitively) against the display's product name.
    let match: [String]
    /// Optional EDID identifiers (vendor + product number, as CoreGraphics
    /// reports them). More robust than name matching — it survives renames and
    /// localization, and is how the wider ecosystem (ddccontrol, Lunar) keys
    /// monitors. The wizard records these for every profile it generates.
    var edid: [EDIDMatch]?
    let controls: [Control]
    /// Optional human note; ignored by the app.
    var comment: String?
    var schemaVersion: Int?

    struct EDIDMatch: Codable, Equatable {
        var vendor: Int
        var product: Int
    }

    /// Matches on EDID (vendor+product) when available, otherwise on a product-name
    /// substring. EDID is preferred because it's exact.
    func matches(productName: String, vendor: Int?, product: Int?) -> Bool {
        if let edid, let vendor, let product,
           edid.contains(where: { $0.vendor == vendor && $0.product == product }) {
            return true
        }
        return match.contains { productName.range(of: $0, options: .caseInsensitive) != nil }
    }
}

struct Control: Codable {
    enum Kind: String, Codable {
        case group     // top-level heading (separator + bold label)
        case section   // sub-heading within a group
        case range     // slider, min...max
        case cycle     // pick one of N options
        case toggle    // on/off
    }

    enum ByteSelector: String, Codable { case high, low }

    let kind: Kind
    var label: String? = nil

    // DDC addressing
    var vcp: HexValue? = nil    // feature code, e.g. "60"
    var channel: HexValue? = nil // high byte for channel-multiplexed writes (chan<<8 | value)
    var byte: ByteSelector? = nil // which byte this control occupies in a packed 16-bit register
                                // (e.g. d9 = (temp<<8)|brightness): read and written together

    // range
    var min: Int? = nil
    var max: Int? = nil
    var step: Int? = nil

    // cycle
    var options: [Option]? = nil

    // toggle
    var onValue: HexValue? = nil
    var offValue: HexValue? = nil

    // quirks
    var noRead: Bool? = nil     // value can't be read back; keep a local copy
    var noVerify: Bool? = nil   // monitor lies on read-back after a write

    /// Render this control disabled (read-only) while another control holds a
    /// given value — e.g. Moon Halo Brightness is read-only when the Moon Halo
    /// switch is on Auto.
    var disableWhen: Condition? = nil

    /// Hide this control entirely while another control holds a given value —
    /// e.g. Low Blue Light is unavailable in the sRGB color mode.
    var hideWhen: Condition? = nil

    struct Option: Codable {
        var value: HexValue? = nil // DDC value; nil for a system option (e.g. HDR)
        let label: String
        var hdr: Bool? = nil       // true → toggles the macOS system HDR setting, not DDC
    }

    struct Condition: Codable {
        var vcp: HexValue?         // the other control's feature code…
        var channel: HexValue?     // its channel, if multiplexed
        var equals: HexValue?      // matches when that control == this value…
        var equalsAny: [HexValue]? // …or equals any of these values
        var system: String?        // …or a system state: "hdr" matches when macOS HDR is on
    }

    // MARK: Convenience

    var featureCode: UInt8? { vcp.map { UInt8($0.value & 0xFF) } }
    var channelByte: UInt8? { channel.map { UInt8($0.value & 0xFF) } }
    var stepValue: Int { Swift.max(1, step ?? 1) }
    var isHeader: Bool { kind == .group || kind == .section }
    var isReadable: Bool { vcp != nil && noRead != true && !isHeader }

    /// Stable key identifying this control's value within a display (a feature
    /// code can back two controls — Moon Halo brightness vs. color temp both
    /// live on d9, distinguished by channel or packed byte).
    var stateKey: String { "\(vcp?.value ?? -1)/\(channel?.value ?? -1)/\(byte?.rawValue ?? "")" }

    /// Interpret a raw read value against this control: returns a human label
    /// (option name / "On" / "Off" / the in-range number) when the value is one
    /// this control recognises, or nil when it doesn't. Used by Listen mode to
    /// flag recognised vs. unrecognised values.
    func recognise(_ raw: Int) -> String? {
        let v = byteValue(raw)
        switch kind {
        case .cycle:
            return options?.first(where: { $0.value?.value == v })?.label
        case .toggle:
            if v == onValue?.value { return "On" }
            if v == offValue?.value { return "Off" }
            return nil
        case .range:
            let lo = min ?? 0
            let hi = max ?? Int.max
            return (v >= lo && v <= hi) ? "\(v)" : nil
        case .group, .section:
            return nil
        }
    }

    /// Extract this control's portion of a raw register value: the high or low
    /// byte for a packed register (`byte`), the low byte for a channel-multiplexed
    /// register, otherwise the whole value.
    func byteValue(_ raw: Int) -> Int {
        switch byte {
        case .high: return (raw >> 8) & 0xFF
        case .low: return raw & 0xFF
        case nil: return channelByte != nil ? (raw & 0xFF) : raw
        }
    }

    /// Interpret a raw 16-bit DDC read for THIS control as a clamped value.
    func interpretRead(_ raw: Int) -> Int? {
        clampedRange(byteValue(raw))
    }

    private func clampedRange(_ v: Int) -> Int {
        guard kind == .range else { return v }
        let lo = min ?? 0
        let hi = max ?? v
        return Swift.min(Swift.max(v, lo), hi)
    }
}

enum MonitorConfigStore {
    static var userDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Didact/Monitors", isDirectory: true)
    }

    /// Load every monitor config from the bundle and the user directory. Files
    /// that don't parse as a monitor config are skipped silently — the bundle
    /// also contains unrelated JSON.
    static func load() -> [MonitorConfig] {
        var configs: [MonitorConfig] = []
        let decoder = JSONDecoder()

        // User-directory files first so a re-taught profile takes precedence over
        // a bundled one for the same monitor (display matching picks the first
        // match, see AppDelegate.rescanDisplays).
        var urls: [URL] = []
        ensureUserDirectory()
        if let userFiles = try? FileManager.default.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: nil) {
            urls += userFiles.filter { $0.pathExtension.lowercased() == "json" }
        }
        if let bundled = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            urls += bundled
        }

        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let config = try? decoder.decode(MonitorConfig.self, from: data),
                  !config.controls.isEmpty else { continue }
            configs.append(config)
        }
        return configs
    }

    /// Only the bundled (trusted, curated) profiles — used as the source for the
    /// wizard's auto-fill, so a user's own earlier (possibly wrong) profile can't
    /// feed its mistakes back in.
    static func loadBundled() -> [MonitorConfig] {
        let decoder = JSONDecoder()
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let config = try? decoder.decode(MonitorConfig.self, from: data),
                  !config.controls.isEmpty else { return nil }
            return config
        }
    }

    static func ensureUserDirectory() {
        try? FileManager.default.createDirectory(
            at: userDirectory, withIntermediateDirectories: true)
    }

    /// Carry over profiles taught under the app's former name (BtnQ) the first
    /// time the renamed app runs: copy `…/BtnQ/Monitors/*.json` into the new
    /// `…/Didact/Monitors` if the new folder has none yet. No-op afterwards.
    static func migrateLegacyMonitorsIfNeeded() {
        let fm = FileManager.default
        ensureUserDirectory()
        let current = (try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        guard !current.contains(where: { $0.pathExtension.lowercased() == "json" }) else { return }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacy = base.appendingPathComponent("BtnQ/Monitors", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            try? fm.copyItem(at: file, to: userDirectory.appendingPathComponent(file.lastPathComponent))
        }
    }

    /// The file URL a config with this name would be written to.
    static func fileURL(forName name: String) -> URL {
        userDirectory.appendingPathComponent(filename(forName: name))
    }

    /// `BenQ RD280UG` → `BenQ-RD280UG.json`. Collapses any run of non-alphanumeric
    /// characters to a single dash so the filename is filesystem-safe.
    static func filename(forName name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return (out.isEmpty ? "Monitor" : out) + ".json"
    }

    /// Write a config to the user Monitors directory as pretty-printed JSON.
    /// Throws `CocoaError(.fileWriteFileExists)` when a file of the same name
    /// already exists and `overwriting` is false. Returns the written URL.
    @discardableResult
    static func save(_ config: MonitorConfig, overwriting: Bool) throws -> URL {
        ensureUserDirectory()
        let url = fileURL(forName: config.name)
        if !overwriting, FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
        return url
    }
}
