//
//  MCCS.swift
//  Didact
//
//  The VESA Monitor Control Command Set (MCCS 2.2a) VCP code catalogue: the
//  standard name, type and class of each defined feature code. We use it to NAME
//  and CLASSIFY the codes a monitor advertises — so the wizard can offer the
//  standard controls it understands and never blindly pokes a code whose meaning
//  is undefined.
//
//  Trust boundary (per the spec):
//    • 00h–BFh   — well-established standard meanings, reliable across monitors.
//    • C0h–DFh   — standardised but routinely REPURPOSED by manufacturers (e.g. D0h
//                  is "Output Select" in MCCS yet BenQ uses it for Night Level), so
//                  the name is only a hint here.
//    • E0h–FFh   — explicitly Manufacturer Specific / undefined (MCCS §8.8).
//  `offerable` therefore only vouches for 00h–BFh writable, non-destructive codes.
//

import Foundation

struct MCCSCode {
    let name: String
    let writable: Bool      // R/W or W/O (false = read-only, can't be a control)
    let continuous: Bool    // true = a range (C), false = enumerated/non-continuous (NC)
    /// A normal adjustable control — false for destructive triggers (factory
    /// restores, degauss, save) and status/diagnostic codes we must never offer.
    let safe: Bool
    /// Standard names for a non-continuous code's defined values, when MCCS spells
    /// them out (so a discrete control reads "Max Image", not "Mode 0x02").
    var values: [Int: String]? = nil
}

enum MCCS {
    /// Look up a code's standard name, if any.
    static func name(_ code: UInt8) -> String? { catalog[code]?.name }

    /// The standard name of a specific value on a code, if MCCS defines one.
    static func valueName(_ code: UInt8, _ value: Int) -> String? { catalog[code]?.values?[value] }

    /// A code we can safely OFFER as a user control: a reliably-named standard code
    /// (below the OEM-repurposed C0h range), writable, and not destructive/diagnostic.
    static func offerable(_ code: UInt8) -> Bool {
        guard code < 0xC0, let c = catalog[code] else { return false }
        return c.writable && c.safe
    }

    static func isContinuous(_ code: UInt8) -> Bool { catalog[code]?.continuous ?? false }

    // R/W adjustable unless noted. `safe: false` marks destructive triggers and
    // read-only status codes — named so we can recognise and skip them.
    static let catalog: [UInt8: MCCSCode] = [
        // Preset operations — destructive / infrastructure (never offered)
        0x00: MCCSCode(name: "VCP Code Page",                writable: true,  continuous: false, safe: false),
        0x01: MCCSCode(name: "Degauss",                      writable: true,  continuous: false, safe: false),
        0x04: MCCSCode(name: "Restore Factory Defaults",     writable: true,  continuous: false, safe: false),
        0x05: MCCSCode(name: "Restore Factory Luminance/Contrast", writable: true, continuous: false, safe: false),
        0x06: MCCSCode(name: "Restore Factory Geometry",     writable: true,  continuous: false, safe: false),
        0x08: MCCSCode(name: "Restore Factory Color",        writable: true,  continuous: false, safe: false),
        0x0A: MCCSCode(name: "Restore Factory TV Defaults",  writable: true,  continuous: false, safe: false),
        0xB0: MCCSCode(name: "Settings (Save/Restore)",      writable: true,  continuous: false, safe: false),
        0x52: MCCSCode(name: "Active Control",               writable: false, continuous: false, safe: false),

        // Image / luminance
        0x0E: MCCSCode(name: "Clock",                        writable: true,  continuous: true,  safe: true),
        0x10: MCCSCode(name: "Brightness",                   writable: true,  continuous: true,  safe: true),
        0x12: MCCSCode(name: "Contrast",                     writable: true,  continuous: true,  safe: true),
        0x1C: MCCSCode(name: "Focus",                        writable: true,  continuous: true,  safe: true),
        0x1E: MCCSCode(name: "Auto Setup",                   writable: true,  continuous: false, safe: false),
        0x3E: MCCSCode(name: "Clock Phase",                  writable: true,  continuous: true,  safe: true),
        0x54: MCCSCode(name: "Performance Preservation",     writable: true,  continuous: false, safe: true),
        0x56: MCCSCode(name: "Horizontal Moiré",             writable: true,  continuous: true,  safe: true),
        0x58: MCCSCode(name: "Vertical Moiré",               writable: true,  continuous: true,  safe: true),
        0x72: MCCSCode(name: "Gamma",                        writable: true,  continuous: false, safe: true),
        0x7C: MCCSCode(name: "Adjust Zoom",                  writable: true,  continuous: true,  safe: true),
        0x86: MCCSCode(name: "Display Scaling",              writable: true,  continuous: false, safe: true,
                       values: [0x01: "No Scaling", 0x02: "Max Image", 0x03: "Max Vertical",
                                0x04: "Max Horizontal", 0x05: "Max Vertical (AR)", 0x06: "Max Horizontal (AR)",
                                0x07: "Full", 0x08: "Zoom", 0x09: "Squeeze", 0x0A: "Variable"]),
        0x82: MCCSCode(name: "Horizontal Mirror",            writable: true,  continuous: false, safe: true),
        0x84: MCCSCode(name: "Vertical Mirror",              writable: true,  continuous: false, safe: true),
        0x88: MCCSCode(name: "Velocity Scan Modulation",     writable: true,  continuous: false, safe: true),
        0x8C: MCCSCode(name: "Sharpness",                    writable: true,  continuous: true,  safe: true),

        // Backlight levels
        0x6B: MCCSCode(name: "Backlight Level: White",       writable: true,  continuous: true,  safe: false),
        0x6D: MCCSCode(name: "Backlight Level: Red",         writable: true,  continuous: true,  safe: false),
        0x6F: MCCSCode(name: "Backlight Level: Green",       writable: true,  continuous: true,  safe: false),
        0x71: MCCSCode(name: "Backlight Level: Blue",        writable: true,  continuous: true,  safe: false),

        // Color
        0x0B: MCCSCode(name: "Color Temperature Increment",  writable: false, continuous: false, safe: false),
        0x0C: MCCSCode(name: "Color Temperature Request",    writable: true,  continuous: true,  safe: true),
        0x11: MCCSCode(name: "Flesh Tone Enhancement",       writable: true,  continuous: true,  safe: true),
        0x14: MCCSCode(name: "Color Preset",                 writable: true,  continuous: false, safe: true,
                       values: [0x01: "sRGB", 0x02: "Native", 0x03: "4000K", 0x04: "5000K",
                                0x05: "6500K", 0x06: "7500K", 0x08: "9300K", 0x0B: "User"]),
        0x16: MCCSCode(name: "Video Gain: Red",              writable: true,  continuous: true,  safe: false),
        0x17: MCCSCode(name: "User Vision Compensation",     writable: true,  continuous: true,  safe: true),
        0x18: MCCSCode(name: "Video Gain: Green",            writable: true,  continuous: true,  safe: false),
        0x1A: MCCSCode(name: "Video Gain: Blue",             writable: true,  continuous: true,  safe: false),
        0x1F: MCCSCode(name: "Auto Color Setup",             writable: true,  continuous: false, safe: false),
        0x2E: MCCSCode(name: "Grey Scale Expansion",         writable: true,  continuous: false, safe: true),
        0x6C: MCCSCode(name: "Video Black Level: Red",       writable: true,  continuous: true,  safe: true),
        0x6E: MCCSCode(name: "Video Black Level: Green",     writable: true,  continuous: true,  safe: true),
        0x70: MCCSCode(name: "Video Black Level: Blue",      writable: true,  continuous: true,  safe: true),
        0x8A: MCCSCode(name: "Color Saturation",             writable: true,  continuous: true,  safe: true),
        0x90: MCCSCode(name: "Hue",                          writable: true,  continuous: true,  safe: true),
        0x59: MCCSCode(name: "6-Axis Saturation: Red",       writable: true,  continuous: true,  safe: true),
        0x5A: MCCSCode(name: "6-Axis Saturation: Yellow",    writable: true,  continuous: true,  safe: true),
        0x5B: MCCSCode(name: "6-Axis Saturation: Green",     writable: true,  continuous: true,  safe: true),
        0x5C: MCCSCode(name: "6-Axis Saturation: Cyan",      writable: true,  continuous: true,  safe: true),
        0x5D: MCCSCode(name: "6-Axis Saturation: Blue",      writable: true,  continuous: true,  safe: true),
        0x5E: MCCSCode(name: "6-Axis Saturation: Magenta",   writable: true,  continuous: true,  safe: true),
        0x9B: MCCSCode(name: "6-Axis Hue: Red",              writable: true,  continuous: true,  safe: true),
        0x9C: MCCSCode(name: "6-Axis Hue: Yellow",           writable: true,  continuous: true,  safe: true),
        0x9D: MCCSCode(name: "6-Axis Hue: Green",            writable: true,  continuous: true,  safe: true),
        0x9E: MCCSCode(name: "6-Axis Hue: Cyan",             writable: true,  continuous: true,  safe: true),
        0x9F: MCCSCode(name: "6-Axis Hue: Blue",             writable: true,  continuous: true,  safe: true),
        0xA0: MCCSCode(name: "6-Axis Hue: Magenta",          writable: true,  continuous: true,  safe: true),

        // Audio
        0x62: MCCSCode(name: "Speaker Volume",               writable: true,  continuous: true,  safe: true),
        0x63: MCCSCode(name: "Speaker Pair Select",          writable: true,  continuous: false, safe: true),
        0x64: MCCSCode(name: "Microphone Volume",            writable: true,  continuous: true,  safe: true),
        0x65: MCCSCode(name: "Audio Jack Status",            writable: false, continuous: false, safe: false),
        0x8D: MCCSCode(name: "Audio Mute",                   writable: true,  continuous: false, safe: true,
                       values: [0x01: "Mute", 0x02: "Un-mute"]),
        0x8F: MCCSCode(name: "Audio Treble",                 writable: true,  continuous: true,  safe: true),
        0x91: MCCSCode(name: "Audio Bass",                   writable: true,  continuous: true,  safe: true),

        // Display controls (C0h+: standardised but often repurposed — name is a hint)
        0x60: MCCSCode(name: "Input Select",                 writable: true,  continuous: false, safe: true,
                       values: [0x01: "VGA-1", 0x03: "DVI-1", 0x04: "DVI-2", 0x0F: "DisplayPort-1",
                                0x10: "DisplayPort-2", 0x11: "HDMI-1", 0x12: "HDMI-2"]),
        0xAA: MCCSCode(name: "Screen Orientation",           writable: false, continuous: false, safe: false),
        0xB6: MCCSCode(name: "Display Technology Type",      writable: false, continuous: false, safe: false),
        0xCA: MCCSCode(name: "OSD",                          writable: true,  continuous: false, safe: true),
        0xCC: MCCSCode(name: "OSD Language",                 writable: true,  continuous: false, safe: true),
        0xD0: MCCSCode(name: "Output Select",                writable: true,  continuous: false, safe: true),
        0xD4: MCCSCode(name: "Stereo Video Mode",            writable: true,  continuous: false, safe: true),
        0xD6: MCCSCode(name: "Power Mode",                   writable: true,  continuous: false, safe: false,
                       values: [0x01: "On", 0x02: "Standby", 0x03: "Suspend", 0x04: "Off", 0x05: "Hard Off"]),
        0xDA: MCCSCode(name: "Scan Mode",                    writable: true,  continuous: false, safe: true,
                       values: [0x00: "Normal", 0x01: "Underscan", 0x02: "Overscan"]),
        0xDB: MCCSCode(name: "Image Mode",                   writable: true,  continuous: false, safe: true,
                       values: [0x00: "None", 0x01: "Full", 0x02: "Zoom", 0x03: "Squeeze", 0x04: "Variable"]),
        0xDC: MCCSCode(name: "Display Application",          writable: true,  continuous: false, safe: true),
        0xDF: MCCSCode(name: "VCP Version",                  writable: false, continuous: false, safe: false),
    ]
}
