//
//  ControlTemplate.swift
//  BtnQ
//
//  The catalogue of controls the Teach wizard walks through, in "most common
//  first" order. Each entry knows the control's KIND; only the VCP CODE is
//  unknown for a given monitor, so that's what the wizard learns.
//
//  Controls are tiered. UNIVERSAL controls use VESA MCCS standard codes with
//  spec-defined meanings — they work on essentially any monitor and the wizard
//  auto-detects them with no button press. PROPRIETARY controls (Moon Halo, the
//  BenQ colour-mode register) have no standard code; they're taught by
//  observation, and because their values are model-specific the wizard learns
//  the values from the monitor / lets the user label them rather than asserting a
//  fixed list (the template options are only a hint for known BenQ models).
//

import Foundation

struct ControlTemplate {
    enum Tier { case universal, proprietary }

    struct OptionTemplate {
        let value: Int
        let label: String
    }

    let label: String
    let kind: Control.Kind
    let tier: Tier

    /// The VESA MCCS standard feature code, when this control has one. The wizard
    /// reads/probes it directly; proprietary controls leave this nil.
    let standardCode: UInt8?

    // range
    var suggestedMin: Int?
    /// Used only when the monitor reports a max of 0 for a range.
    var fallbackMax: Int?

    // cycle — for universal controls these are authoritative; for proprietary
    // ones they're only a hint (known-BenQ values), and unknowns are learned.
    var options: [OptionTemplate]?

    // toggle
    var onValue: Int?
    var offValue: Int?

    // quirks carried straight into the generated Control
    var noRead = false
    var noVerify = false

    /// What to tell the user to do during the manual teach step.
    let action: String

    static let all: [ControlTemplate] = [
        // ── Universal (standard MCCS) ─────────────────────────────────────────
        ControlTemplate(
            label: "Brightness", kind: .range, tier: .universal, standardCode: 0x10,
            suggestedMin: 0, fallbackMax: 100,
            action: "change Brightness up and down"),
        ControlTemplate(
            label: "Contrast", kind: .range, tier: .universal, standardCode: 0x12,
            suggestedMin: 0, fallbackMax: 100,
            action: "change Contrast up and down"),
        ControlTemplate(
            label: "Volume", kind: .range, tier: .universal, standardCode: 0x62,
            suggestedMin: 0, fallbackMax: 100,
            action: "change the Volume up and down"),
        ControlTemplate(
            label: "Source", kind: .cycle, tier: .universal, standardCode: 0x60,
            options: [
                .init(value: 0x0F, label: "DisplayPort"),
                .init(value: 0x11, label: "HDMI"),
                .init(value: 0x13, label: "USB-C"),
            ],
            action: "switch the Input Source between two inputs"),
        ControlTemplate(
            label: "Color Temperature", kind: .cycle, tier: .universal, standardCode: 0x14,
            options: [   // MCCS standard colour-preset values
                .init(value: 0x01, label: "sRGB"),
                .init(value: 0x02, label: "Native"),
                .init(value: 0x03, label: "4000K"),
                .init(value: 0x04, label: "5000K"),
                .init(value: 0x05, label: "6500K"),
                .init(value: 0x06, label: "7500K"),
                .init(value: 0x08, label: "9300K"),
                .init(value: 0x0B, label: "User"),
            ],
            action: "change the Colour Temperature / preset"),
        ControlTemplate(
            label: "Sharpness", kind: .range, tier: .universal, standardCode: 0x87,
            suggestedMin: 0, fallbackMax: 10,
            action: "change Sharpness up and down"),

        // ── Proprietary (no standard code; values model-specific) ─────────────
        ControlTemplate(
            label: "Color Mode", kind: .cycle, tier: .proprietary, standardCode: nil,
            options: [   // hint for known BenQ models; unknown values are learned/labelled
                .init(value: 0x30, label: "Coding - Dark Theme"),
                .init(value: 0x31, label: "Coding - Light Theme"),
                .init(value: 0x3A, label: "Coding - Paper Color"),
                .init(value: 0x0F, label: "M-book"),
                .init(value: 0x32, label: "Cinema"),
                .init(value: 0x28, label: "Game"),
                .init(value: 0x1F, label: "ePaper"),
                .init(value: 0x0A, label: "sRGB"),
                .init(value: 0x12, label: "User"),
            ],
            action: "switch the Color/Picture Mode between two presets"),
        ControlTemplate(
            label: "Moon Halo", kind: .cycle, tier: .proprietary, standardCode: nil,
            options: [
                .init(value: 0x30, label: "Auto"),
                .init(value: 0x20, label: "On"),
                .init(value: 0x10, label: "Off"),
            ],
            noRead: true, noVerify: true,
            action: "switch Moon Halo between On and Off"),
    ]
}
