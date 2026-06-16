//
//  ControlTemplate.swift
//  BtnQ
//
//  The fixed catalogue of controls the Teach wizard walks through, in
//  "most common first" order. Each entry already knows the control's KIND and
//  (for cycles/toggles) its option values and labels — only the VCP CODE is
//  unknown for a given monitor, so that's all the wizard learns. Standard VESA
//  MCCS controls carry their spec-defined code in `standardCode`, which lets the
//  wizard auto-detect them with no button press; proprietary controls (Moon
//  Halo, Color Mode) leave it nil and are taught by observation.
//

import Foundation

struct ControlTemplate {
    struct OptionTemplate {
        let value: Int
        let label: String
    }

    let label: String
    let kind: Control.Kind

    /// The VESA MCCS standard feature code, when this control has one. The
    /// wizard can read/probe it directly (its meaning is fixed by the spec);
    /// proprietary controls leave this nil and must be taught by button press.
    let standardCode: UInt8?

    // range
    var suggestedMin: Int?
    /// Used only when the monitor reports a max of 0 for a range.
    var fallbackMax: Int?

    // cycle
    var options: [OptionTemplate]?

    // toggle
    var onValue: Int?
    var offValue: Int?

    // quirks carried straight into the generated Control
    var noRead = false
    var noVerify = false

    /// What to tell the user to do during the manual teach step.
    let action: String

    /// In "most common first" order: brightness, contrast, volume, input,
    /// then the proprietary extras, with Moon Halo last.
    static let all: [ControlTemplate] = [
        ControlTemplate(
            label: "Brightness", kind: .range, standardCode: 0x10,
            suggestedMin: 0, fallbackMax: 100,
            action: "change Brightness up and down"),
        ControlTemplate(
            label: "Contrast", kind: .range, standardCode: 0x12,
            suggestedMin: 0, fallbackMax: 100,
            action: "change Contrast up and down"),
        ControlTemplate(
            label: "Volume", kind: .range, standardCode: 0x62,
            suggestedMin: 0, fallbackMax: 100,
            action: "change the Volume up and down"),
        ControlTemplate(
            label: "Source", kind: .cycle, standardCode: 0x60,
            options: [
                .init(value: 0x0F, label: "DisplayPort"),
                .init(value: 0x11, label: "HDMI"),
                .init(value: 0x13, label: "USB-C"),
            ],
            action: "switch the Input Source between two inputs"),
        ControlTemplate(
            label: "Color Mode", kind: .cycle, standardCode: nil,
            options: [
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
            action: "switch the Color Mode between two presets"),
        ControlTemplate(
            label: "Moon Halo", kind: .cycle, standardCode: nil,
            options: [
                .init(value: 0x30, label: "Auto"),
                .init(value: 0x20, label: "On"),
                .init(value: 0x10, label: "Off"),
            ],
            noRead: true, noVerify: true,
            action: "switch Moon Halo between On and Off"),
    ]
}
