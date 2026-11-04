
import AppKit

// NX_KEYTYPE_* values.
enum MediaKey: Int, Equatable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
}

struct MediaKeyEvent {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
    let isUp: Bool
    let modifiers: NSEvent.ModifierFlags
}

enum MediaKeyParser {
    static let auxControlSubtype = 8

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
