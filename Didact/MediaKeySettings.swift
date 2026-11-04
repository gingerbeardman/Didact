//
//  MediaKeySettings.swift
//  Didact
//
//  Which physical media keys Didact is allowed to take over. The master switch
//  is deliberately separate from the two role switches: both roles default to on
//  so enabling the feature is a single explicit action, and a user who only wants
//  brightness (or only audio) can turn the other role off without losing the
//  master setting.
//

import Foundation

struct MediaKeySettings: Equatable {
    var masterEnabled: Bool = false
    var brightnessEnabled: Bool = true
    var audioEnabled: Bool = true

    /// True only when the tap has something to do.
    var isActive: Bool {
        masterEnabled && (brightnessEnabled || audioEnabled)
    }

    /// A master switch with both role groups off would request Accessibility for
    /// nothing, so normalize it away.
    var normalized: MediaKeySettings {
        guard !brightnessEnabled, !audioEnabled else { return self }
        var copy = self
        copy.masterEnabled = false
        return copy
    }
}

enum MediaKeySettingsStore {
    /// The existing key, kept so anyone already testing the feature retains it.
    static let masterKey = "mediaKeysEnabled"
    static let brightnessKey = "mediaKeyBrightnessEnabled"
    static let audioKey = "mediaKeyAudioEnabled"

    static func load(from defaults: UserDefaults = .standard) -> MediaKeySettings {
        MediaKeySettings(
            masterEnabled: defaults.bool(forKey: masterKey),
            brightnessEnabled: defaults.object(forKey: brightnessKey) as? Bool ?? true,
            audioEnabled: defaults.object(forKey: audioKey) as? Bool ?? true)
    }

    @discardableResult
    static func save(_ settings: MediaKeySettings,
                     to defaults: UserDefaults = .standard) -> MediaKeySettings {
        let normalized = settings.normalized
        defaults.set(normalized.masterEnabled, forKey: masterKey)
        defaults.set(normalized.brightnessEnabled, forKey: brightnessKey)
        defaults.set(normalized.audioEnabled, forKey: audioKey)
        return normalized
    }
}
