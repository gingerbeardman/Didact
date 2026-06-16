//
//  KnownProfileMatcher.swift
//  BtnQ
//
//  Uses existing monitor profiles (bundled or user) to auto-fill controls the
//  capabilities dump confirms, so a monitor similar to one we already know needs
//  little or no manual teaching. Conservative by design:
//
//    • A control is a PERFECT match only when its code is present and — for a
//      cycle/toggle — the advertised value set equals the profile's exactly, or
//      — for a range — the code is continuous (no value list). These are imported
//      with high confidence.
//    • A profile that perfectly matches at least one control is "anchored": we
//      then also trust its companions that the capabilities string can't verify
//      byte-for-byte — multiplexed registers (e.g. Moon Halo's D9 brightness /
//      colour temp) and bare-listed cycles (Moon Halo itself) — provided their
//      code is present. This is the small, deliberate risk: if Moon Halo is
//      there, its siblings almost certainly are too.
//

import Foundation

enum KnownProfileMatcher {
    static func confirmedControls(from configs: [MonitorConfig],
                                  capabilities: [UInt8: [Int]]) -> [Control] {
        guard !capabilities.isEmpty else { return [] }
        var byKey: [String: Control] = [:]

        for config in configs {
            let coded = config.controls.filter { $0.featureCode != nil && !$0.isHeader }
            let perfect = coded.filter { isPerfectMatch($0, capabilities) }
            guard !perfect.isEmpty else { continue }   // never trust a profile we can't anchor

            for control in perfect where byKey[control.stateKey] == nil {
                byKey[control.stateKey] = control
            }
            // Anchored companions the dump can't verify directly.
            for control in coded where !isPerfectMatch(control, capabilities) {
                guard let code = control.featureCode, capabilities[code] != nil,
                      byKey[control.stateKey] == nil else { continue }
                let multiplexed = control.byte != nil || control.channel != nil
                let bareCycle = control.kind == .cycle && (capabilities[code]?.isEmpty ?? true)
                if multiplexed || bareCycle { byKey[control.stateKey] = control }
            }
        }
        return Array(byKey.values)
    }

    /// The known profile this monitor *is*, if the capabilities dump confirms it
    /// distinctively — i.e. a vendor-range cycle/toggle (not the universal
    /// brightness/contrast/etc. that every monitor shares) matches exactly. When
    /// found, the wizard can adopt the whole profile (full control set, correct
    /// order, all named modes) rather than reconstructing from the raw dump.
    static func recognizedProfile(from configs: [MonitorConfig],
                                  capabilities: [UInt8: [Int]]) -> MonitorConfig? {
        guard !capabilities.isEmpty else { return nil }
        var best: (config: MonitorConfig, score: Int)?
        for config in configs {
            let coded = config.controls.filter { $0.featureCode != nil && !$0.isHeader }
            let perfect = coded.filter { isPerfectMatch($0, capabilities) }
            // Require a distinctive anchor: a vendor-code cycle/toggle whose value
            // set matched. Standard codes alone (present on every monitor) must not
            // trigger a false recognition.
            let distinctive = perfect.contains {
                ($0.kind == .cycle || $0.kind == .toggle) && ($0.featureCode ?? 0) >= 0xC0
            }
            guard distinctive, perfect.count > (best?.score ?? 0) else { continue }
            best = (config, perfect.count)
        }
        return best?.config
    }

    private static func isPerfectMatch(_ control: Control, _ caps: [UInt8: [Int]]) -> Bool {
        guard let code = control.featureCode, let values = caps[code] else { return false }
        guard control.byte == nil, control.channel == nil else { return false }   // can't verify multiplexed
        switch control.kind {
        case .range:
            return values.isEmpty                                   // continuous feature
        case .cycle:
            let options = Set((control.options ?? []).compactMap { $0.value?.value })
            return !values.isEmpty && options == Set(values)
        case .toggle:
            let onOff = Set([control.onValue?.value, control.offValue?.value].compactMap { $0 })
            return !values.isEmpty && onOff == Set(values)
        case .group, .section:
            return false
        }
    }
}
