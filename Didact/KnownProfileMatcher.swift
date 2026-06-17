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

            // A profile is trusted for its MODEL-SPECIFIC controls — ones with
            // conditional logic (hideWhen/disableWhen) or values we can't verify by
            // read-back (noRead/noVerify), plus the unverifiable companions below —
            // only when it matches DISTINCTIVELY: a vendor-range cycle/toggle, not the
            // universal codes every monitor shares. Without that, a bare standard code
            // (e.g. a continuous 0xE5) would drag in another model's "Sensitivity"
            // and its hideWhen wholesale.
            let distinctive = isDistinctiveMatch(perfect)

            for control in perfect where byKey[control.stateKey] == nil {
                // Generic universal controls (a standard MCCS code, no conditions)
                // import freely. Anything keyed to a vendor code or carrying model-
                // specific logic imports only when we recognize the monitor — so a
                // bare standard code can't drag in another model's vendor controls.
                if !isGeneric(control) && !distinctive { continue }
                byKey[control.stateKey] = control
            }
            // Anchored companions the dump can't verify directly — only when the
            // profile is the monitor (distinctive), so a generic-only match can't
            // import another model's bare cycles or multiplexed registers.
            guard distinctive else { continue }
            for control in coded where !isPerfectMatch(control, capabilities) {
                guard let code = control.featureCode, capabilities[code] != nil,
                      byKey[control.stateKey] == nil else { continue }
                let multiplexed = control.byte != nil || control.channel != nil || control.valueMask != nil
                let bareCycle = control.kind == .cycle && (capabilities[code]?.isEmpty ?? true)
                if multiplexed || bareCycle { byKey[control.stateKey] = control }
            }
        }
        return Array(byKey.values)
    }

    /// A control whose correctness depends on the specific model: conditional logic
    /// keyed to other registers, or values that can't be confirmed by read-back.
    /// Safe to auto-fill only from a profile we recognize distinctively.
    private static func isModelSpecific(_ c: Control) -> Bool {
        c.hideWhen != nil || c.disableWhen != nil || c.noRead == true || c.noVerify == true
    }

    /// A control safe to import on any anchored profile: a standard MCCS code
    /// (< 0xC0) with spec-defined meaning and no model-specific quirks. Vendor-code
    /// controls (≥ 0xC0) are model-specific by nature even without conditions.
    private static func isGeneric(_ c: Control) -> Bool {
        (c.featureCode ?? 0xFF) < 0xC0 && !isModelSpecific(c)
    }

    /// A distinctive anchor: a perfectly-matched vendor-range (≥0xC0) cycle/toggle,
    /// not the universal brightness/contrast/input codes every monitor shares.
    private static func isDistinctiveMatch(_ perfect: [Control]) -> Bool {
        perfect.contains {
            ($0.kind == .cycle || $0.kind == .toggle) && ($0.featureCode ?? 0) >= 0xC0
        }
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
            guard isDistinctiveMatch(perfect), perfect.count > (best?.score ?? 0) else { continue }
            best = (config, perfect.count)
        }
        return best?.config
    }

    private static func isPerfectMatch(_ control: Control, _ caps: [UInt8: [Int]]) -> Bool {
        guard let code = control.featureCode, let values = caps[code] else { return false }
        guard control.byte == nil, control.channel == nil, control.valueMask == nil else { return false }   // can't verify shared-register controls
        switch control.kind {
        case .range:
            // A continuous feature, or a stepped range whose advertised steps all
            // fall within the profile's declared span (e.g. Night Level d0 = 1…10
            // advertised as D0(01…0A)). Enumerated steps don't make it not-a-range.
            if values.isEmpty { return true }
            let lo = control.min ?? 0, hi = control.max ?? Int.max
            return values.allSatisfy { $0 >= lo && $0 <= hi }
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
