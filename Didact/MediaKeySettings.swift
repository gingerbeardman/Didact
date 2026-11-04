
import Foundation

struct MediaKeySettings: Equatable {
    var masterEnabled: Bool = false
    var brightnessEnabled: Bool = true
    var audioEnabled: Bool = true

    var isActive: Bool {
        masterEnabled && (brightnessEnabled || audioEnabled)
    }

    var normalized: MediaKeySettings {
        guard !brightnessEnabled, !audioEnabled else { return self }
        var copy = self
        copy.masterEnabled = false
        return copy
    }
}

enum MediaKeySettingsStore {
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
