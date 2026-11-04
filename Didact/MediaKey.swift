//
//  MediaKey.swift
//  Didact
//
//  Parsing for the five system-defined keys a monitor can use over DDC:
//  brightness up/down, volume up/down and mute. macOS delivers these as
//  NX_SYSDEFINED events (type 14, subtype 8); the key code is in the high word of
//  data1 and the press state/repeat flag in the low word.
//

import AppKit

enum MediaKey: Int, Equatable {
    case volumeUp = 0      // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1    // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7          // NX_KEYTYPE_MUTE
}

struct MediaKeyEvent {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
    let isUp: Bool
    let modifiers: NSEvent.ModifierFlags
}

enum MediaKeyParser {
    /// The subtype used by the auxiliary-control (media key) event family.
    static let auxControlSubtype = 8

    /// Parse the raw fields. Kept separate from NSEvent so it can be unit-tested
    /// without synthesising a system event.
    static func parse(subtype: Int, data1: Int, modifiers: NSEvent.ModifierFlags) -> MediaKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }

        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let flags = data1 & 0x0000_FFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB,
              let key = MediaKey(rawValue: keyCode) else { return nil }

        let isDown = state == 0xA
        let isUp = state == 0xB
        let isRepeat = isDown && (flags & 0x1) == 0x1
        return MediaKeyEvent(key: key, isDown: isDown, isRepeat: isRepeat,
                             isUp: isUp, modifiers: modifiers)
    }

    static func parse(_ event: NSEvent) -> MediaKeyEvent? {
        guard event.type == .systemDefined else { return nil }
        return parse(subtype: Int(event.subtype.rawValue), data1: event.data1,
                     modifiers: event.modifierFlags)
    }
}
